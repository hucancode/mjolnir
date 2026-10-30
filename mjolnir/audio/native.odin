#+build !js
package audio

import "../containers"
import "core:fmt"
import "core:log"
import "core:strings"
import ma "vendor:miniaudio"

// Audio is a playback device mixing voices. Must not move after init (the mixer keeps
// pointers into it).
Audio :: struct {
  using _: Audio_State,
}

@(private)
Audio_State :: struct {
  engine:      ma.engine,
  buses:       [Bus]ma.sound_group,
  sound_slots: containers.Slots,
  sounds:      []ma.sound, // decoded once; voices copy them
  voice_slots: containers.Slots,
  voices:      []ma.sound,
  voice_sound: []Sound,
}

// init opens the default playback device; false when there is none.
init :: proc(self: ^Audio) -> bool {
  config := ma.engine_config_init()
  if r := ma.engine_init(&config, &self.engine); r != .SUCCESS {
    log.errorf("Failed to open audio device: %s", ma.result_description(r))
    return false
  }
  for &g in self.buses do ma.sound_group_init(&self.engine, {}, nil, &g)
  containers.slots_init(&self.sound_slots, MAX_SOUNDS)
  containers.slots_init(&self.voice_slots, MAX_VOICES)
  self.sounds = make([]ma.sound, MAX_SOUNDS)
  self.voices = make([]ma.sound, MAX_VOICES)
  self.voice_sound = make([]Sound, MAX_VOICES)
  return true
}

// shutdown stops every voice, destroys every sound and closes the device.
shutdown :: proc(self: ^Audio) {
  teardown(self)
  for &g in self.buses do ma.sound_group_uninit(&g)
  ma.engine_uninit(&self.engine)
  containers.slots_destroy(&self.sound_slots)
  containers.slots_destroy(&self.voice_slots)
  delete(self.sounds)
  delete(self.voices)
  delete(self.voice_sound)
}

// teardown stops every voice, destroys every sound and resets the volumes and the listener,
// leaving the device as init opened it.
teardown :: proc(self: ^Audio) {
  cursor: u32
  for i in containers.slots_next(&self.sound_slots, &cursor) do sound_destroy(self, Sound(i))
  set_volume(self, 1)
  for b in Bus do set_bus_volume(self, b, 1)
  set_listener(self, {}, {0, 0, -1})
}

// sound_create_file decodes the audio file (WAV, FLAC or MP3) at path; false when it cannot.
sound_create_file :: proc(self: ^Audio, path: string) -> (sound: Sound, ok: bool) #optional_ok {
  index := alloc_sound(self) or_return
  return decode(self, index, strings.clone_to_cstring(path, context.temp_allocator))
}

// sound_create_memory decodes an audio file's bytes (WAV, FLAC or MP3), e.g. from #load. The
// bytes must outlive the sound.
sound_create_memory :: proc(self: ^Audio, data: []u8) -> (sound: Sound, ok: bool) #optional_ok {
  index := alloc_sound(self) or_return
  name := registered_name(index)
  ma.resource_manager_register_encoded_data(ma.engine_get_resource_manager(&self.engine), name, raw_data(data), len(data))
  return decode(self, index, name)
}

// sound_create_samples takes interleaved samples in [-1, 1] at sample_rate per second. The
// samples must outlive the sound.
sound_create_samples :: proc(self: ^Audio, samples: []f32, channels: u32, sample_rate: u32) -> (sound: Sound, ok: bool) #optional_ok {
  index := alloc_sound(self) or_return
  name := registered_name(index)
  frames := u64(len(samples)) / u64(channels)
  ma.resource_manager_register_decoded_data(ma.engine_get_resource_manager(&self.engine), name, raw_data(samples), frames, .f32, channels, sample_rate)
  return decode(self, index, name)
}

// sound_create makes a sound from a file path, encoded bytes or samples.
sound_create :: proc {
  sound_create_file,
  sound_create_memory,
  sound_create_samples,
}

// sound_destroy stops the sound's voices and frees it.
sound_destroy :: proc(self: ^Audio, sound: Sound) {
  if !containers.slots_live(&self.sound_slots, u32(sound)) do return
  cursor: u32
  for i in containers.slots_next(&self.voice_slots, &cursor) do if self.voice_sound[i] == sound do free_voice(self, i)
  ma.sound_uninit(&self.sounds[sound])
  ma.resource_manager_unregister_data(ma.engine_get_resource_manager(&self.engine), registered_name(u32(sound)))
  containers.slots_free(&self.sound_slots, u32(sound))
}

// play starts a voice of the sound on a bus; with a position it is heard from there by the
// listener, else as is. Finished voices free themselves; a zero Voice when all are playing.
play :: proc(self: ^Audio, sound: Sound, bus := Bus.EFFECTS, volume: f32 = 1, pitch: f32 = 1, loop := false, position: Maybe([3]f32) = nil) -> Voice {
  if !containers.slots_live(&self.sound_slots, u32(sound)) do return {}
  cursor: u32
  for i in containers.slots_next(&self.voice_slots, &cursor) do if ma.sound_at_end(&self.voices[i]) do free_voice(self, i)
  i, ok := containers.slots_alloc(&self.voice_slots)
  if !ok do return {}
  v := &self.voices[i]
  if ma.sound_init_copy(&self.engine, &self.sounds[sound], {}, &self.buses[bus], v) != .SUCCESS {
    containers.slots_free(&self.voice_slots, i)
    return {}
  }
  self.voice_sound[i] = sound
  ma.sound_set_volume(v, volume)
  ma.sound_set_pitch(v, pitch)
  ma.sound_set_looping(v, b32(loop))
  p, spatial := position.?
  ma.sound_set_spatialization_enabled(v, b32(spatial))
  ma.sound_set_position(v, p.x, p.y, p.z)
  ma.sound_start(v)
  return Voice(containers.slots_handle(&self.voice_slots, i))
}

// voice_stop ends the voice.
voice_stop :: proc(self: ^Audio, voice: Voice) {
  if containers.slots_valid(&self.voice_slots, voice) do free_voice(self, voice.index)
}

// voice_playing reports whether the voice is still playing.
voice_playing :: proc(self: ^Audio, voice: Voice) -> bool {
  return containers.slots_valid(&self.voice_slots, voice) && bool(ma.sound_is_playing(&self.voices[voice.index]))
}

// voice_set_volume scales the voice's loudness; 1 is as recorded.
voice_set_volume :: proc(self: ^Audio, voice: Voice, volume: f32) {
  if containers.slots_valid(&self.voice_slots, voice) do ma.sound_set_volume(&self.voices[voice.index], volume)
}

// voice_set_pitch scales the voice's playback speed and pitch; 1 is as recorded.
voice_set_pitch :: proc(self: ^Audio, voice: Voice, pitch: f32) {
  if containers.slots_valid(&self.voice_slots, voice) do ma.sound_set_pitch(&self.voices[voice.index], pitch)
}

// voice_set_position moves the voice to position in the world, heard from the listener.
voice_set_position :: proc(self: ^Audio, voice: Voice, position: [3]f32) {
  if !containers.slots_valid(&self.voice_slots, voice) do return
  v := &self.voices[voice.index]
  ma.sound_set_spatialization_enabled(v, true)
  ma.sound_set_position(v, position.x, position.y, position.z)
}

// set_listener places the ears positional voices are heard from: forward is where they face,
// up their top.
set_listener :: proc(self: ^Audio, position, forward: [3]f32, up := [3]f32{0, 1, 0}) {
  ma.engine_listener_set_position(&self.engine, 0, position.x, position.y, position.z)
  ma.engine_listener_set_direction(&self.engine, 0, forward.x, forward.y, forward.z)
  ma.engine_listener_set_world_up(&self.engine, 0, up.x, up.y, up.z)
}

// set_volume scales everything played; 1 is full.
set_volume :: proc(self: ^Audio, volume: f32) {
  ma.engine_set_volume(&self.engine, volume)
}

// set_bus_volume scales the voices on bus; 1 is full.
set_bus_volume :: proc(self: ^Audio, bus: Bus, volume: f32) {
  ma.sound_group_set_volume(&self.buses[bus], volume)
}

@(private = "file")
alloc_sound :: proc(self: ^Audio) -> (index: u32, ok: bool) {
  index, ok = containers.slots_alloc(&self.sound_slots)
  if !ok do log.errorf("Failed to create sound: all %d in use", MAX_SOUNDS)
  return
}

// Decodes the resource `name` (a path or registered data) into sound `index`; frees the index
// and the registration on failure.
@(private = "file")
decode :: proc(self: ^Audio, index: u32, name: cstring) -> (Sound, bool) {
  if r := ma.sound_init_from_file(&self.engine, name, {.DECODE}, nil, nil, &self.sounds[index]); r != .SUCCESS {
    log.errorf("Failed to create sound '%s': %s", name, ma.result_description(r))
    ma.resource_manager_unregister_data(ma.engine_get_resource_manager(&self.engine), registered_name(index))
    containers.slots_free(&self.sound_slots, index)
    return 0, false
  }
  return Sound(index), true
}

// Data handed over in memory is registered with the decoder under a name of its sound's index.
@(private = "file")
registered_name :: proc(index: u32) -> cstring {
  return fmt.ctprintf("mjolnir.audio.%d", index)
}

@(private = "file")
free_voice :: proc(self: ^Audio, index: u32) {
  ma.sound_uninit(&self.voices[index])
  containers.slots_free(&self.voice_slots, index)
}
