package input

// KeySet holds one flag per key, indexed by Key.
KeySet :: [MAX_KEYS]bool
// ButtonSet is a set of held or edged mouse buttons.
ButtonSet :: bit_set[MouseButton]

// TEXT_CAPACITY is the bytes of typed text kept per tick.
TEXT_CAPACITY :: 128

// State is one tick of input: the key_* and mouse_* queries read it, and its fields hold the
// cursor, its movement and the scroll in window pixels, plus which devices a consumer captured.
State :: struct {
  cursor:           [2]f32, // window pixels, origin top-left
  mouse_delta:      [2]f32,
  scroll:           [2]f32,
  // Set by the first consumer that claims the device this tick (debug UI,
  // then game UI). Later consumers skip a captured device.
  mouse_captured:    bool,
  keyboard_captured: bool,
  using _: State_Private,
}

@(private)
State_Private :: struct {
  keys:             KeySet,
  keys_pressed:     KeySet,
  keys_released:    KeySet,
  keys_repeated:    KeySet,
  buttons:          ButtonSet,
  buttons_pressed:  ButtonSet,
  buttons_released: ButtonSet,
  text_buf:         [TEXT_CAPACITY]u8,
  text_len:         int,
  primed:           bool, // cursor seen once; the first tick has no delta
}

// key_down reports whether `key` is held.
key_down :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys[key]
}

// key_pressed reports whether `key` went down this tick.
key_pressed :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys_pressed[key]
}

// key_released reports whether `key` went up this tick.
key_released :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys_released[key]
}

// key_repeated reports OS key auto-repeat fired this tick (the key is held).
key_repeated :: proc(self: ^State, key: Key) -> bool {
  return key_valid(key) && self.keys_repeated[key]
}

// mouse_down reports whether `button` is held.
mouse_down :: proc(self: ^State, button: MouseButton) -> bool {
  return button in self.buttons
}

// mouse_pressed reports whether `button` went down this tick.
mouse_pressed :: proc(self: ^State, button: MouseButton) -> bool {
  return button in self.buttons_pressed
}

// mouse_released reports whether `button` went up this tick.
mouse_released :: proc(self: ^State, button: MouseButton) -> bool {
  return button in self.buttons_released
}

// text returns the UTF-8 text typed this tick.
text :: proc(self: ^State) -> string {
  return string(self.text_buf[:self.text_len])
}

// axis returns -1 while only `neg` is held, +1 while only `pos` is held, else 0.
axis :: proc(self: ^State, neg, pos: Key) -> f32 {
  return f32(int(key_down(self, pos))) - f32(int(key_down(self, neg)))
}

// next_key_edge iterates this tick's key edges. A key with both edges this tick yields them
// in the order that leaves it in its current state.
//   it := 0
//   for key, pressed in input.next_key_edge(&s, &it) {...}
next_key_edge :: proc(self: ^State, it: ^int) -> (key: Key, pressed: bool, ok: bool) {
  for it^ < 2 * MAX_KEYS {
    i, second := it^ / 2, it^ % 2 == 1
    p, r := self.keys_pressed[i], self.keys_released[i]
    if !p && !r || second && !(p && r) {
      it^ = 2 * (i + 1)
      continue
    }
    it^ += 1
    // both edges: down now means release came first
    release_first := p && r && self.keys[i]
    if p && r do return Key(i), release_first == second, true
    return Key(i), p, true
  }
  return
}

@(private)
key_valid :: proc(key: Key) -> bool {
  return i32(key) >= 0 && i32(key) < MAX_KEYS
}
