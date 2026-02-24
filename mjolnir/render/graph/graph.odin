package render_graph

import "core:log"
import "core:fmt"

// Result type for graph operations
Result :: enum {
	SUCCESS,
	ERROR_CYCLIC_DEPENDENCY,
	ERROR_MISSING_RESOURCE,
	ERROR_INVALID_PASS,
}

// Transient resource pool (placeholder for future implementation)
TransientResourcePool :: struct {
	// TODO: Implement transient resource aliasing
}

// Core Graph type
Graph :: struct {
	// Resource registry (string name -> descriptor)
	resources:    map[string]ResourceDescriptor,
	resource_ids: map[string]ResourceId,  // name -> ID lookup

	// Pass registry (template declarations)
	pass_templates: [dynamic]PassTemplate,

	// Compiled pass instances (after instantiation)
	passes:   [dynamic]PassInstance,
	pass_ids: map[string]PassId,  // name -> ID lookup

	// Compiled execution plan
	execution_order: [dynamic]PassId,
	barriers:        map[PassId][dynamic]Barrier,

	// Transient allocator (future: for memory aliasing)
	transient_pool: TransientResourcePool,

	// Resource counter for ID generation
	next_resource_id: u32,
}

// Initialize empty graph
init :: proc(g: ^Graph) {
	g.resources = make(map[string]ResourceDescriptor)
	g.resource_ids = make(map[string]ResourceId)
	g.pass_templates = make([dynamic]PassTemplate)
	g.passes = make([dynamic]PassInstance)
	g.pass_ids = make(map[string]PassId)
	g.execution_order = make([dynamic]PassId)
	g.barriers = make(map[PassId][dynamic]Barrier)
	g.next_resource_id = 0
}

// Cleanup graph resources
destroy :: proc(g: ^Graph) {
	delete(g.resources)
	delete(g.resource_ids)
	delete(g.pass_templates)

	// Clean up pass instances
	for &pass in g.passes {
		delete(pass.inputs)
		delete(pass.outputs)
		// Instance name is allocated, free it if it's not the template name
		if pass.instance_name != pass.template_name {
			delete(pass.instance_name)
		}
	}
	delete(g.passes)
	delete(g.pass_ids)

	delete(g.execution_order)
	for _, barriers in g.barriers {
		delete(barriers)
	}
	delete(g.barriers)
}

// Reset graph for next frame (clears pass instances, keeps templates)
reset :: proc(g: ^Graph) {
	// Clean up pass instances
	for &pass in g.passes {
		delete(pass.inputs)
		delete(pass.outputs)
		if pass.instance_name != pass.template_name {
			delete(pass.instance_name)
		}
	}
	clear(&g.passes)
	clear(&g.pass_ids)
	clear(&g.execution_order)

	for _, barriers in g.barriers {
		delete(barriers)
	}
	clear(&g.barriers)

	// NOTE: We DO clear templates because they're registered fresh each frame
	// with stack-allocated context pointers that become invalid after the frame
	clear(&g.pass_templates)
}

// Register resource in graph
register_resource :: proc(g: ^Graph, desc: ResourceDescriptor) -> ResourceId {
	// Check if resource already exists
	if existing_id, ok := g.resource_ids[desc.name]; ok {
		log.warnf("Resource '%s' already registered, returning existing ID", desc.name)
		return existing_id
	}

	g.resources[desc.name] = desc
	id := ResourceId(g.next_resource_id)
	g.resource_ids[desc.name] = id
	g.next_resource_id += 1
	return id
}

// Add pass template to graph
add_pass_template :: proc(g: ^Graph, template: PassTemplate) {
	append(&g.pass_templates, template)
	log.infof("Registered pass template: %s (scope: %v, queue: %v)", template.name, template.scope, template.queue)
}

// Instantiate pass templates for active cameras/lights
instantiate_passes :: proc(
	g: ^Graph,
	active_cameras: []u32,
	active_lights: []u32,
) -> Result {
	for &template in g.pass_templates {
		switch template.scope {
		case .GLOBAL:
			// Single instance, no scope index
			instance := create_pass_instance(g, &template, 0)
			append(&g.passes, instance)
			g.pass_ids[instance.instance_name] = PassId(len(g.passes) - 1)

		case .PER_CAMERA:
			// One instance per active camera
			for cam_index in active_cameras {
				instance := create_pass_instance(g, &template, cam_index)
				append(&g.passes, instance)
				g.pass_ids[instance.instance_name] = PassId(len(g.passes) - 1)
			}

		case .PER_LIGHT:
			// One instance per shadow-casting light
			for light_index in active_lights {
				instance := create_pass_instance(g, &template, light_index)
				append(&g.passes, instance)
				g.pass_ids[instance.instance_name] = PassId(len(g.passes) - 1)
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
		template_name = template.name,
		instance_name = make_instance_name(template.name, template.scope, scope_index),
		scope_index = scope_index,
		queue = template.queue,
		execute = template.execute,
		user_data = template.user_data,
		inputs = make([dynamic]ResourceId),
		outputs = make([dynamic]ResourceId),
	}

	pass_id := PassId(len(g.passes))

	// Call setup proc to populate inputs/outputs
	builder := PassBuilder{
		graph = g,
		pass_id = pass_id,
		scope_index = scope_index,
		inputs = make([dynamic]ResourceId),
		outputs = make([dynamic]ResourceId),
	}
	template.setup(&builder, template.user_data)

	instance.inputs = builder.inputs
	instance.outputs = builder.outputs

	return instance
}

// Compile graph: build execution order and compute barriers
compile :: proc(g: ^Graph) -> Result {
	if err := build_execution_order(g); err != .SUCCESS {
		return err
	}
	if err := compute_barriers(g); err != .SUCCESS {
		return err
	}
	return .SUCCESS
}

// Build dependency graph via topological sort (Kahn's algorithm)
build_execution_order :: proc(g: ^Graph) -> Result {
	// Build adjacency list and in-degree counts
	in_degree := make(map[PassId]int)
	adj_list := make(map[PassId][dynamic]PassId)
	defer delete(in_degree)
	defer {
		for _, list in adj_list {
			delete(list)
		}
		delete(adj_list)
	}

	// Initialize in-degrees
	for pass_id in 0..<len(g.passes) {
		in_degree[PassId(pass_id)] = 0
	}

	// Build edges: if pass A writes resource R and pass B reads R, edge A->B
	for &pass_a, idx_a in g.passes {
		for output_res in pass_a.outputs {
			// Find all passes that read this output
			for &pass_b, idx_b in g.passes {
				if idx_a == idx_b do continue

				for input_res in pass_b.inputs {
					if input_res == output_res {
						// Edge: pass_a -> pass_b
						if _, ok := adj_list[PassId(idx_a)]; !ok {
							adj_list[PassId(idx_a)] = make([dynamic]PassId)
						}
						append(&adj_list[PassId(idx_a)], PassId(idx_b))
						in_degree[PassId(idx_b)] += 1
					}
				}
			}
		}
	}

	// Kahn's topological sort
	queue := make([dynamic]PassId)
	defer delete(queue)

	for pass_id, degree in in_degree {
		if degree == 0 {
			append(&queue, pass_id)
		}
	}

	clear(&g.execution_order)
	for len(queue) > 0 {
		// Pop front
		current := queue[0]
		ordered_remove(&queue, 0)

		append(&g.execution_order, current)

		if neighbors, ok := adj_list[current]; ok {
			for neighbor in neighbors {
				in_degree[neighbor] -= 1
				if in_degree[neighbor] == 0 {
					append(&queue, neighbor)
				}
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
