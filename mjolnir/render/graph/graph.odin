package render_graph

// Package render_graph implements a Frostbite-inspired frame graph for automatic
// resource dependency tracking and barrier insertion.
//
// The graph follows a three-phase execution model:
//
// SETUP PHASE:
//   1. graph_init() - Initialize empty graph
//   2. graph_register_resource() - Declare all resources (buffers, textures)
//   3. graph_register_pass() - Declare all passes with inputs/outputs
//   4. Repeat steps 2-3 each frame
//
// COMPILE PHASE:
//   5. graph_compile() - Build execution order and compute barriers
//      - Instantiates pass templates (PER_CAMERA, PER_LIGHT expansion)
//      - Topological sort (Kahn's algorithm)
//      - Automatic barrier inference from resource access patterns
//
// EXECUTE PHASE:
//   6. graph_execute() - Render frame with automatic synchronization
//      - Emits barriers before each pass
//      - Calls pass execute callbacks with resolved resources
//
// Example usage:
//
//   g: Graph
//   graph_init(&g)
//
//   // Setup phase (each frame)
//   graph_register_resource(&g, "depth", depth_desc)
//   graph_register_pass(&g, GEOMETRY_PASS, active_cameras, geometry_execute, &ctx)
//
//   // Compile phase
//   if graph_compile(&g) != .SUCCESS {
//       log.error("Graph compilation failed")
//   }
//
//   // Execute phase
//   graph_execute(&g, cmd, frame_index, &exec_ctx)

import "core:log"
import "core:slice"
import "core:strings"
import "core:fmt"

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

@(private)
_transient_pool_init :: proc(pool: ^TransientResourcePool) {
	pool.transient_resources = make([dynamic]TransientResourceInfo)
}

@(private)
_transient_pool_destroy :: proc(pool: ^TransientResourcePool) {
	delete(pool.transient_resources)
}

@(private)
_transient_pool_begin_frame :: proc(pool: ^TransientResourcePool) {
	clear(&pool.transient_resources)
}

@(private)
_transient_pool_compile :: proc(pool: ^TransientResourcePool, g: ^Graph) -> Result {
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

// ============================================================================
// PUBLIC API - SETUP PHASE
// ============================================================================

// Initialize empty graph
graph_init :: proc(g: ^Graph) {
	g.resources = make(map[ResourceId]ResourceDescriptor)
	g.pass_templates = make([dynamic]PassTemplate)
	g.passes = make([dynamic]PassInstance)
	g.execution_order = make([dynamic]PassId)
	g.barriers = make(map[PassId][dynamic]Barrier)
	g.resource_lifetimes = make(map[ResourceId]ResourceLifetime)
	_transient_pool_init(&g.transient_pool)
}

// Cleanup graph resources
graph_destroy :: proc(g: ^Graph) {
	_clear_compiled_state(g)

	delete(g.resources)
	delete(g.pass_templates)
	delete(g.passes)

	delete(g.execution_order)
	delete(g.barriers)
	delete(g.resource_lifetimes)
	_transient_pool_destroy(&g.transient_pool)
}

// Reset graph for next frame (clears pass instances, keeps templates)
graph_reset :: proc(g: ^Graph) {
	_clear_compiled_state(g)
	_transient_pool_begin_frame(&g.transient_pool)

	// NOTE: We DO clear templates because they're registered fresh each frame
	// with stack-allocated context pointers that become invalid after the frame
	clear(&g.pass_templates)
}

// ============================================================================
// PRIVATE HELPERS
// ============================================================================

@(private)
_clear_compiled_state :: proc(g: ^Graph) {
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

// Register resource in graph
graph_register_resource :: proc(g: ^Graph, resource_id: string, desc: ResourceDescriptor) {
	id := ResourceId(resource_id)

	if id in g.resources {
		log.warnf("Resource '%s' already registered", resource_id)
		return
	}

	g.resources[id] = desc
}

// Register pass template (declarative, with inputs/outputs)
// Combines declarative structure (inputs/outputs) with runtime behavior (execute callback)
graph_register_pass :: proc(
	g: ^Graph,
	decl: PassTemplate, // Declarative template with inputs/outputs
	instance_indices: []u32, // Active camera/light indices
	execute: PassExecuteProc, // Execute callback (runtime)
	user_data: rawptr, // User data (runtime)
) {
	template := decl
	template.instance_indices = instance_indices
	template.execute = execute
	template.user_data = user_data

	append(&g.pass_templates, template)
	log.infof("Registered pass template: %s (scope: %v, queue: %v)", template.name, template.scope, template.queue)
}

// ============================================================================
// PRIVATE HELPERS
// ============================================================================

@(private)
_get_resource_descriptor :: proc(g: ^Graph, res_id: ResourceId) -> (ResourceDescriptor, bool) {
	desc, ok := g.resources[res_id]
	return desc, ok
}

// ============================================================================
// PUBLIC API - COMPILE PHASE
// ============================================================================

// Compile graph: instantiate passes, build execution order, compute barriers
graph_compile :: proc(g: ^Graph) -> Result {
	_clear_compiled_state(g)
	if err := _instantiate_passes(g); err != .SUCCESS do return err
	if err := _validate_passes(g); err != .SUCCESS do return err
	if err := _build_execution_order(g); err != .SUCCESS do return err
	_compute_resource_lifetimes(g)
	if err := _transient_pool_compile(&g.transient_pool, g); err != .SUCCESS do return err
	if err := _compute_barriers(g); err != .SUCCESS do return err
	return .SUCCESS
}

// ============================================================================
// PRIVATE COMPILATION STAGES
// ============================================================================

@(private)
_instantiate_passes :: proc(g: ^Graph) -> Result {
	for &template in g.pass_templates {
		switch template.scope {
		case .GLOBAL:
			instance := _create_pass_instance(g, &template, 0)
			append(&g.passes, instance)

		case .PER_CAMERA:
			for cam_index in template.instance_indices {
				instance := _create_pass_instance(g, &template, cam_index)
				append(&g.passes, instance)
			}

		case .PER_LIGHT:
			for light_index in template.instance_indices {
				instance := _create_pass_instance(g, &template, light_index)
				append(&g.passes, instance)
			}
		}
	}

	log.infof("Instantiated %d passes from %d templates", len(g.passes), len(g.pass_templates))
	return .SUCCESS
}

@(private)
_expand_template_string :: proc(template: string, scope_index: u32, scope: PassScope) -> string {
	switch scope {
	case .PER_CAMERA:
		// Replace {cam} with camera index
		if strings.contains(template, "{cam}") {
			// Find {cam} and replace it
			before, after, was_allocation := strings.partition(template, "{cam}")
			return fmt.tprintf("%s%d%s", before, scope_index, after)
		}

	case .PER_LIGHT:
		// Replace {slot} with light slot index
		if strings.contains(template, "{slot}") {
			// Find {slot} and replace it
			before, after, was_allocation := strings.partition(template, "{slot}")
			return fmt.tprintf("%s%d%s", before, scope_index, after)
		}

	case .GLOBAL:
		// No expansion needed for global passes
	}

	// No template tokens found, return as-is
	return template
}

@(private)
_create_pass_instance :: proc(
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

	// Declarative path: expand template strings
	for input_template in template.inputs {
		expanded := _expand_template_string(input_template, scope_index, template.scope)
		append(&instance.inputs, ResourceId(expanded))
	}
	for output_template in template.outputs {
		expanded := _expand_template_string(output_template, scope_index, template.scope)
		append(&instance.outputs, ResourceId(expanded))
	}
	instance.is_valid = true

	return instance
}

@(private)
_validate_passes :: proc(g: ^Graph) -> Result {
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

@(private)
_compute_resource_lifetimes :: proc(g: ^Graph) {
	clear(&g.resource_lifetimes)
	for pass_id, step_idx in g.execution_order {
		pass := &g.passes[pass_id]
		for res_id in pass.inputs {
			_record_resource_lifetime(g, res_id, step_idx)
		}
		for res_id in pass.outputs {
			_record_resource_lifetime(g, res_id, step_idx)
		}
	}
}

@(private)
_record_resource_lifetime :: proc(g: ^Graph, res_id: ResourceId, step_idx: int) {
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

@(private)
_pass_reads_resource :: proc(pass: ^PassInstance, res_id: ResourceId) -> bool {
	for input_res in pass.inputs {
		if input_res == res_id {
			return true
		}
	}
	return false
}

@(private)
_pass_writes_resource :: proc(pass: ^PassInstance, res_id: ResourceId) -> bool {
	for output_res in pass.outputs {
		if output_res == res_id {
			return true
		}
	}
	return false
}

@(private)
_build_execution_order :: proc(g: ^Graph) -> Result {
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
			reads := _pass_reads_resource(pass, res_id)
			writes := _pass_writes_resource(pass, res_id)
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
