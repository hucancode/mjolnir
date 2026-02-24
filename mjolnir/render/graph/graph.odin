package render_graph

import "core:log"
import "core:slice"

// Result type for graph operations
Result :: enum {
	SUCCESS,
	ERROR_CYCLIC_DEPENDENCY,
	ERROR_MISSING_RESOURCE,
	ERROR_INVALID_PASS,
}

ResourceLifetime :: struct {
	first_use_step: int,
	last_use_step:  int,
}

TransientResourceInfo :: struct {
	resource_id: ResourceId,
	desc:        ResourceDescriptor,
	lifetime:    ResourceLifetime,
}

// Reserved for transient allocation/aliasing implementation.
TransientResourcePool :: struct {
	transient_resources: [dynamic]TransientResourceInfo,
}

// Core Graph type
Graph :: struct {
	// Resource registry (resource ID == resource name)
	resources: map[ResourceId]ResourceDescriptor,

	// Pass registry (template declarations)
	pass_templates: [dynamic]PassTemplate,

	// Compiled pass instances (after instantiation)
	passes: [dynamic]PassInstance,

	// Compiled execution plan
	execution_order: [dynamic]PassId,
	barriers:        map[PassId][dynamic]Barrier,
	resource_lifetimes: map[ResourceId]ResourceLifetime,

	// Internal seam for transient allocation/aliasing.
	transient_pool: TransientResourcePool,
}

transient_pool_init :: proc(pool: ^TransientResourcePool) {
	pool.transient_resources = make([dynamic]TransientResourceInfo)
}

transient_pool_destroy :: proc(pool: ^TransientResourcePool) {
	delete(pool.transient_resources)
}

transient_pool_begin_frame :: proc(pool: ^TransientResourcePool) {
	clear(&pool.transient_resources)
}

transient_pool_compile :: proc(pool: ^TransientResourcePool, g: ^Graph) -> Result {
	clear(&pool.transient_resources)
	for res_id, desc in g.resources {
		if !desc.is_transient do continue
		lifetime, has_lifetime := g.resource_lifetimes[res_id]
		if !has_lifetime do continue
		append(&pool.transient_resources, TransientResourceInfo{
			resource_id = res_id,
			desc = desc,
			lifetime = lifetime,
		})
	}
	slice.sort_by(pool.transient_resources[:], proc(a, b: TransientResourceInfo) -> bool {
		if a.lifetime.first_use_step != b.lifetime.first_use_step {
			return a.lifetime.first_use_step < b.lifetime.first_use_step
		}
		if a.lifetime.last_use_step != b.lifetime.last_use_step {
			return a.lifetime.last_use_step > b.lifetime.last_use_step
		}
		return string(a.resource_id) < string(b.resource_id)
	})
	if len(pool.transient_resources) > 0 {
		log.infof("Transient compile prepared %d resources", len(pool.transient_resources))
	}
	return .SUCCESS
}

// Initialize empty graph
init :: proc(g: ^Graph) {
	g.resources = make(map[ResourceId]ResourceDescriptor)
	g.pass_templates = make([dynamic]PassTemplate)
	g.passes = make([dynamic]PassInstance)
	g.execution_order = make([dynamic]PassId)
	g.barriers = make(map[PassId][dynamic]Barrier)
	g.resource_lifetimes = make(map[ResourceId]ResourceLifetime)
	transient_pool_init(&g.transient_pool)
}

clear_compiled_state :: proc(g: ^Graph) {
	for &pass in g.passes {
		delete(pass.inputs)
		delete(pass.outputs)
	}
	clear(&g.passes)

	clear(&g.execution_order)
	for _, barriers in g.barriers {
		delete(barriers)
	}
	clear(&g.barriers)

	clear(&g.resource_lifetimes)
}

// Cleanup graph resources
destroy :: proc(g: ^Graph) {
	clear_compiled_state(g)

	delete(g.resources)
	delete(g.pass_templates)
	delete(g.passes)

	delete(g.execution_order)
	delete(g.barriers)
	delete(g.resource_lifetimes)
	transient_pool_destroy(&g.transient_pool)
}

// Reset graph for next frame (clears pass instances, keeps templates)
reset :: proc(g: ^Graph) {
	clear_compiled_state(g)
	transient_pool_begin_frame(&g.transient_pool)

	// NOTE: We DO clear templates because they're registered fresh each frame
	// with stack-allocated context pointers that become invalid after the frame
	clear(&g.pass_templates)
}

// Register resource in graph
register_resource :: proc(g: ^Graph, resource_id: string, desc: ResourceDescriptor) {
	id := ResourceId(resource_id)

	if id in g.resources {
		log.warnf("Resource '%s' already registered", resource_id)
		return
	}

	g.resources[id] = desc
}

get_resource_descriptor :: proc(g: ^Graph, res_id: ResourceId) -> (ResourceDescriptor, bool) {
	desc, ok := g.resources[res_id]
	return desc, ok
}

// Add pass template to graph
add_pass_template :: proc(g: ^Graph, template: PassTemplate) {
	append(&g.pass_templates, template)
	log.infof("Registered pass template: %s (scope: %v, queue: %v)", template.name, template.scope, template.queue)
}

// Instantiate pass templates using their explicit indices
instantiate_passes :: proc(g: ^Graph) -> Result {
	for &template in g.pass_templates {
		switch template.scope {
		case .GLOBAL:
			instance := create_pass_instance(g, &template, 0)
			append(&g.passes, instance)

		case .PER_CAMERA:
			for cam_index in template.instance_indices {
				instance := create_pass_instance(g, &template, cam_index)
				append(&g.passes, instance)
			}

		case .PER_LIGHT:
			for light_index in template.instance_indices {
				instance := create_pass_instance(g, &template, light_index)
				append(&g.passes, instance)
			}
		}
	}

	log.infof("Instantiated %d passes from %d templates", len(g.passes), len(g.pass_templates))
	return .SUCCESS
}

// Create pass instance by calling setup proc
create_pass_instance :: proc(
	g: ^Graph,
	template: ^PassTemplate,
	scope_index: u32,
) -> PassInstance {
	instance := PassInstance{
		name = template.name,
		scope_index = scope_index,
		queue = template.queue,
		execute = template.execute,
		user_data = template.user_data,
		inputs = make([dynamic]ResourceId),
		outputs = make([dynamic]ResourceId),
		is_valid = true,
	}

	// Call setup proc to populate inputs/outputs
	builder := PassBuilder{
		graph = g,
		scope_index = scope_index,
		inputs = make([dynamic]ResourceId),
		outputs = make([dynamic]ResourceId),
	}
	template.setup(&builder, template.user_data)

	instance.inputs = builder.inputs
	instance.outputs = builder.outputs
	instance.is_valid = !builder.has_missing_resource

	return instance
}

// Compile graph: build execution order and compute barriers
compile :: proc(g: ^Graph) -> Result {
	if err := validate_passes(g); err != .SUCCESS {
		return err
	}
	if err := build_execution_order(g); err != .SUCCESS {
		return err
	}
	compute_resource_lifetimes(g)
	if err := transient_pool_compile(&g.transient_pool, g); err != .SUCCESS {
		return err
	}
	if err := compute_barriers(g); err != .SUCCESS {
		return err
	}
	return .SUCCESS
}

build :: proc(g: ^Graph) -> Result {
	clear_compiled_state(g)
	if err := instantiate_passes(g); err != .SUCCESS {
		return err
	}
	return compile(g)
}

validate_passes :: proc(g: ^Graph) -> Result {
	for pass in g.passes {
		if pass.is_valid {
			continue
		}
		log.errorf("Invalid pass '%s' (scope index: %d): missing graph resources in setup",
			pass.name, pass.scope_index)
		return .ERROR_MISSING_RESOURCE
	}
	return .SUCCESS
}

compute_resource_lifetimes :: proc(g: ^Graph) {
	clear(&g.resource_lifetimes)
	for pass_id, step_idx in g.execution_order {
		pass := &g.passes[pass_id]
		for res_id in pass.inputs {
			record_resource_lifetime(g, res_id, step_idx)
		}
		for res_id in pass.outputs {
			record_resource_lifetime(g, res_id, step_idx)
		}
	}
}

record_resource_lifetime :: proc(g: ^Graph, res_id: ResourceId, step_idx: int) {
	if lifetime, ok := g.resource_lifetimes[res_id]; ok {
		if step_idx < lifetime.first_use_step {
			lifetime.first_use_step = step_idx
		}
		if step_idx > lifetime.last_use_step {
			lifetime.last_use_step = step_idx
		}
		g.resource_lifetimes[res_id] = lifetime
		return
	}
	g.resource_lifetimes[res_id] = ResourceLifetime{
		first_use_step = step_idx,
		last_use_step = step_idx,
	}
}

pass_reads_resource :: proc(pass: ^PassInstance, res_id: ResourceId) -> bool {
	for input_res in pass.inputs {
		if input_res == res_id {
			return true
		}
	}
	return false
}

pass_writes_resource :: proc(pass: ^PassInstance, res_id: ResourceId) -> bool {
	for output_res in pass.outputs {
		if output_res == res_id {
			return true
		}
	}
	return false
}

// Build dependency graph via topological sort (Kahn's algorithm)
build_execution_order :: proc(g: ^Graph) -> Result {
	pass_count := len(g.passes)
	in_degree := make([]int, pass_count)
	defer delete(in_degree)
	adj_list := make([][dynamic]PassId, pass_count)
	defer {
		for &neighbors in adj_list {
			delete(neighbors)
		}
		delete(adj_list)
	}

	add_edge :: proc(
		adj: ^[] [dynamic]PassId,
		in_degree: ^[]int,
		src_idx, dst_idx: int,
	) {
		if src_idx == dst_idx do return
		dst := PassId(dst_idx)
		for existing_dst in adj[src_idx] {
			if existing_dst == dst {
				return
			}
		}
		append(&adj[src_idx], dst)
		in_degree[dst_idx] += 1
	}

	// Build forward dependencies per resource by declaration order.
	// This handles read-write (RMW) resources without generating backward edges.
	for res_id in g.resources {
		last_writer_idx := -1
		readers_since_last_write := make([dynamic]int)

		for pass_idx in 0..<pass_count {
			pass := &g.passes[pass_idx]
			reads := pass_reads_resource(pass, res_id)
			writes := pass_writes_resource(pass, res_id)
			if !reads && !writes do continue

			if reads {
				if last_writer_idx >= 0 {
					add_edge(&adj_list, &in_degree, last_writer_idx, pass_idx)
				}
				append(&readers_since_last_write, pass_idx)
			}

			if writes {
				if last_writer_idx >= 0 {
					add_edge(&adj_list, &in_degree, last_writer_idx, pass_idx)
				}
				for reader_idx in readers_since_last_write {
					add_edge(&adj_list, &in_degree, reader_idx, pass_idx)
				}
				last_writer_idx = pass_idx
				clear(&readers_since_last_write)
			}
		}

		delete(readers_since_last_write)
	}

	// Kahn's topological sort
	queue := make([dynamic]PassId)
	defer delete(queue)

	for pass_idx in 0..<pass_count {
		if in_degree[pass_idx] == 0 {
			append(&queue, PassId(pass_idx))
		}
	}

	clear(&g.execution_order)
	queue_head := 0
	for queue_head < len(queue) {
		current := queue[queue_head]
		queue_head += 1

		append(&g.execution_order, current)

		for neighbor in adj_list[int(current)] {
			neighbor_idx := int(neighbor)
			in_degree[neighbor_idx] -= 1
			if in_degree[neighbor_idx] == 0 {
				append(&queue, neighbor)
			}
		}
	}

	// Detect cycles
	if len(g.execution_order) != len(g.passes) {
		log.errorf("Cyclic dependency detected! Expected %d passes, got %d in execution order",
			len(g.passes), len(g.execution_order))
		return .ERROR_CYCLIC_DEPENDENCY
	}

	log.infof("Built execution order for %d passes", len(g.execution_order))
	return .SUCCESS
}

// Barrier and compute_barriers are defined in barrier.odin
