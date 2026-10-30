#+build js
package audio

// Audio is silent on the web: every proc does nothing and play returns no voice.
Audio :: struct {}

// init succeeds, so a game runs on without sound.
init :: proc(self: ^Audio) -> bool {
  return true
}

// shutdown does nothing.
shutdown :: proc(self: ^Audio) {}

// teardown does nothing.
teardown :: proc(self: ^Audio) {}

// sound_create_file fails: no audio on the web.
sound_create_file :: proc(self: ^Audio, path: string) -> (sound: Sound, ok: bool) #optional_ok {
  return
}

// sound_create_memory fails: no audio on the web.
sound_create_memory :: proc(self: ^Audio, data: []u8) -> (sound: Sound, ok: bool) #optional_ok {
  return
}

// sound_create_samples fails: no audio on the web.
sound_create_samples :: proc(self: ^Audio, samples: []f32, channels: u32, sample_rate: u32) -> (sound: Sound, ok: bool) #optional_ok {
  return
}

// sound_create makes a sound from a file path, encoded bytes or samples.
sound_create :: proc {
  sound_create_file,
  sound_create_memory,
  sound_create_samples,
}

// sound_destroy does nothing.
sound_destroy :: proc(self: ^Audio, sound: Sound) {}

// play returns no voice.
play :: proc(self: ^Audio, sound: Sound, bus := Bus.EFFECTS, volume: f32 = 1, pitch: f32 = 1, loop := false, position: Maybe([3]f32) = nil) -> Voice {
  return {}
}

// voice_stop does nothing.
voice_stop :: proc(self: ^Audio, voice: Voice) {}

// voice_playing is false.
voice_playing :: proc(self: ^Audio, voice: Voice) -> bool {
  return false
}

// voice_set_volume does nothing.
voice_set_volume :: proc(self: ^Audio, voice: Voice, volume: f32) {}

// voice_set_pitch does nothing.
voice_set_pitch :: proc(self: ^Audio, voice: Voice, pitch: f32) {}

// voice_set_position does nothing.
voice_set_position :: proc(self: ^Audio, voice: Voice, position: [3]f32) {}

// set_listener does nothing.
set_listener :: proc(self: ^Audio, position, forward: [3]f32, up := [3]f32{0, 1, 0}) {}

// set_volume does nothing.
set_volume :: proc(self: ^Audio, volume: f32) {}

// set_bus_volume does nothing.
set_bus_volume :: proc(self: ^Audio, bus: Bus, volume: f32) {}
