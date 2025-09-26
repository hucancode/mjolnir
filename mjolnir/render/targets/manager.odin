package targets

import resources "../../resources"

Manager :: struct {
  main:   resources.Handle,
  active: [dynamic]resources.Handle,
}

init :: proc(self: ^Manager, main: resources.Handle) {
  self.main = main
  self.active = make([dynamic]resources.Handle, 0)
}

shutdown :: proc(self: ^Manager) {
  delete(self.active)
  self.active = nil
  self.main = resources.Handle{0, 0}
}

begin_frame :: proc(self: ^Manager) {
  clear(&self.active)
  if self.main.generation != 0 {
    append(&self.active, self.main)
  }
}

contains :: proc(self: ^Manager, handle: resources.Handle) -> bool {
  for existing in self.active {
    if existing.index == handle.index {
      return true
    }
  }
  return false
}

track :: proc(self: ^Manager, handle: resources.Handle) {
  if handle.generation == 0 do return
  if contains(self, handle) do return
  append(&self.active, handle)
}
