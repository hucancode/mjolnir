package crowd

import "core:math"
import "../recast"
import "../detour"

MAX_QUEUE :: 8

Path_Queue_Ref :: distinct u32
PATHQ_INVALID :: Path_Queue_Ref(0)

Path_Query :: struct {
	ref:         Path_Queue_Ref,
	start_pos:   [3]f32,
	end_pos:     [3]f32,
	start_ref:   recast.Poly_Ref,
	end_ref:     recast.Poly_Ref,
	path:        []recast.Poly_Ref,
	npath:       int,
	status:      recast.Status,
	keep_alive:  int,
	filter:      ^detour.Query_Filter,
}

Path_Queue :: struct {
	queue:          [MAX_QUEUE]Path_Query,
	next_handle:    Path_Queue_Ref,
	max_path_size:  int,
	queue_head:     int,
	nav_query:      ^detour.Nav_Mesh_Query,
}

create_path_queue :: proc(max_path_size: int, max_search_node_count: int,
                          nav: ^detour.Nav_Mesh, allocator := context.allocator) -> (queue: ^Path_Queue, ok: bool) {
	context.allocator = allocator
	queue = new(Path_Queue)

	query := new(detour.Nav_Mesh_Query)
	status := detour.nav_mesh_query_init(query, nav, i32(max_search_node_count))
	if recast.status_failed(status) {
		free(query)
		free(queue)
		return nil, false
	}
	queue.nav_query = query

	queue.max_path_size = max_path_size
	for i in 0..<MAX_QUEUE {
		queue.queue[i].ref = PATHQ_INVALID
		queue.queue[i].path = make([]recast.Poly_Ref, max_path_size)
	}

	queue.next_handle = 1
	queue.queue_head = 0

	return queue, true
}

destroy_path_queue :: proc(queue: ^Path_Queue) {
	if queue == nil do return
	detour.nav_mesh_query_destroy(queue.nav_query)
	free(queue.nav_query)
	for i in 0..<MAX_QUEUE {
		delete(queue.queue[i].path)
	}
	free(queue)
}

path_queue_update :: proc(queue: ^Path_Queue, max_iters: int) {
	MAX_KEEP_ALIVE :: 2

	iter_count := max_iters

	for i in 0..<MAX_QUEUE {
		q := &queue.queue[queue.queue_head % MAX_QUEUE]

		if q.ref == PATHQ_INVALID {
			queue.queue_head += 1
			continue
		}

		if recast.status_succeeded(q.status) || recast.status_failed(q.status) {
			q.keep_alive += 1
			if q.keep_alive > MAX_KEEP_ALIVE {
				q.ref = PATHQ_INVALID
				q.status = {}
			}
			queue.queue_head += 1
			continue
		}

		if q.status == {} {
			q.status = detour.init_sliced_find_path(queue.nav_query, q.start_ref, q.end_ref,
			                                        q.start_pos, q.end_pos, q.filter, 0)
		}

		if recast.status_in_progress(q.status) {
			iters: i32
			iters, q.status = detour.update_sliced_find_path(queue.nav_query, i32(iter_count))
			iter_count -= int(iters)
		}

		if recast.status_succeeded(q.status) {
			npath: i32
			q.status, npath = detour.finalize_sliced_find_path(queue.nav_query, q.path,
			                                                    i32(queue.max_path_size))
			q.npath = int(npath)
		}

		if iter_count <= 0 do break

		queue.queue_head += 1
	}
}

path_queue_request :: proc(queue: ^Path_Queue, start_ref: recast.Poly_Ref, end_ref: recast.Poly_Ref,
                            start_pos: [3]f32, end_pos: [3]f32,
                            filter: ^detour.Query_Filter) -> Path_Queue_Ref {
	slot := -1
	for i in 0..<MAX_QUEUE {
		if queue.queue[i].ref == PATHQ_INVALID {
			slot = i
			break
		}
	}

	if slot == -1 do return PATHQ_INVALID

	ref := queue.next_handle
	queue.next_handle += 1
	if queue.next_handle == PATHQ_INVALID {
		queue.next_handle += 1
	}

	q := &queue.queue[slot]
	q.ref = ref
	q.start_pos = start_pos
	q.start_ref = start_ref
	q.end_pos = end_pos
	q.end_ref = end_ref
	q.status = {}
	q.npath = 0
	q.filter = filter
	q.keep_alive = 0

	return ref
}

path_queue_get_request_status :: proc(queue: ^Path_Queue, ref: Path_Queue_Ref) -> recast.Status {
	for i in 0..<MAX_QUEUE {
		if queue.queue[i].ref == ref {
			return queue.queue[i].status
		}
	}
	return {.Invalid_Param}
}

path_queue_get_path_result :: proc(queue: ^Path_Queue, ref: Path_Queue_Ref,
                                    path: []recast.Poly_Ref) -> (npath: int, status: recast.Status) {
	for i in 0..<MAX_QUEUE {
		if queue.queue[i].ref == ref {
			q := &queue.queue[i]
			success_status, detail_status := recast.status_detail(q.status)

			q.ref = PATHQ_INVALID
			q.status = {}

			n := min(q.npath, len(path))
			copy(path[:n], q.path[:n])
			npath = n
			status = detail_status | {.Success}
			return
		}
	}
	return 0, {.Invalid_Param}
}
