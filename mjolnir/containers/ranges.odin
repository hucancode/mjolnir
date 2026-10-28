package containers

// Ranges hands out runs of consecutive indices of storage the caller owns (a GPU buffer), each
// exactly the size asked: first fit, freed runs merged with their free neighbours.
Ranges :: struct {
  capacity: u32,
  using _:  Ranges_State,
}

@(private)
Ranges_State :: struct {
  // free runs as (first, count), by first; touching runs are merged
  free: [dynamic][2]u32,
  // live runs by first: their size and whether ranges_mark kept them
  live: map[u32]Range,
}

@(private)
Range :: struct {
  count: u32,
  kept:  bool,
}

// ranges_init sets up self for indices 0 ..< capacity.
ranges_init :: proc(self: ^Ranges, capacity: u32) {
  self.capacity = capacity
  clear(&self.free)
  clear(&self.live)
  if capacity > 0 do append(&self.free, [2]u32{0, capacity})
}

// ranges_destroy frees the memory held by self and zeroes it.
ranges_destroy :: proc(self: ^Ranges) {
  delete(self.free)
  delete(self.live)
  self^ = {}
}

// ranges_alloc returns the first index of a run of `count`; false when no free run is that long.
// A run of 0 takes nothing and is always there.
ranges_alloc :: proc(self: ^Ranges, count: u32) -> (first: u32, ok: bool) #optional_ok {
  if count == 0 do return 0, true
  for &run, i in self.free do if run[1] >= count {
    first = run[0]
    run[0] += count
    run[1] -= count
    if run[1] == 0 do ordered_remove(&self.free, i)
    self.live[first] = {count = count}
    return first, true
  }
  return 0, false
}

// ranges_size returns the size of the live run at `first`; 0 for none.
ranges_size :: proc(self: ^Ranges, first: u32) -> u32 {
  return self.live[first].count if first in self.live else 0
}

// ranges_free returns the live run at `first`; anything else is ignored.
ranges_free :: proc(self: ^Ranges, first: u32) {
  r, found := self.live[first]
  if !found do return
  delete_key(&self.live, first)
  release(self, first, r.count)
}

// ranges_mark keeps every live run through ranges_rewind.
ranges_mark :: proc(self: ^Ranges) {
  for _, &r in self.live do r.kept = true
}

// ranges_rewind frees every run allocated since ranges_mark (or ranges_init) at once.
ranges_rewind :: proc(self: ^Ranges) {
  doomed := make([dynamic][2]u32, context.temp_allocator)
  for first, r in self.live do if !r.kept do append(&doomed, [2]u32{first, r.count})
  for d in doomed {
    delete_key(&self.live, d[0])
    release(self, d[0], d[1])
  }
}

// Puts a run back in the free list, merged with the free runs it touches.
@(private = "file")
release :: proc(self: ^Ranges, first, count: u32) {
  i := 0
  for i < len(self.free) && self.free[i][0] < first do i += 1
  inject_at(&self.free, i, [2]u32{first, count})
  if i + 1 < len(self.free) && self.free[i][0] + self.free[i][1] == self.free[i + 1][0] {
    self.free[i][1] += self.free[i + 1][1]
    ordered_remove(&self.free, i + 1)
  }
  if i > 0 && self.free[i - 1][0] + self.free[i - 1][1] == self.free[i][0] {
    self.free[i - 1][1] += self.free[i][1]
    ordered_remove(&self.free, i)
  }
}
