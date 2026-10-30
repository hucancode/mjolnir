// Audio on its own: a tone synthesized into samples and a chime encoded as a WAV in memory, played as notes, as a looping voice flying past the listener from left to right, and quieted through a bus. The command line plays and prints it, the web page only prints it (no audio on the web yet).
package main

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:strings"
import "mjolnir/audio"

RATE :: 48000

tone: [RATE / 4]f32
chime: [44 + RATE / 2 * 2]u8

synthesize :: proc() {
  for &s, i in tone {
    t := f32(i) / RATE
    s = 0.4 * math.sin(math.TAU * 440 * t) * (1 - t * 4)
  }
  copy(chime[:], "RIFF")
  endian.put_u32(chime[4:], .Little, len(chime) - 8)
  copy(chime[8:], "WAVEfmt ")
  endian.put_u32(chime[16:], .Little, 16)
  endian.put_u16(chime[20:], .Little, 1)
  endian.put_u16(chime[22:], .Little, 1)
  endian.put_u32(chime[24:], .Little, RATE)
  endian.put_u32(chime[28:], .Little, RATE * 2)
  endian.put_u16(chime[32:], .Little, 2)
  endian.put_u16(chime[34:], .Little, 16)
  copy(chime[36:], "data")
  endian.put_u32(chime[40:], .Little, RATE / 2 * 2)
  for i in 0 ..< RATE / 2 {
    t := f32(i) / RATE
    s := 0.3 * (math.sin(math.TAU * 660 * t) + 0.5 * math.sin(math.TAU * 1320 * t)) * math.exp(-6 * t)
    endian.put_i16(chime[44 + 2 * i:], .Little, i16(s * 32767))
  }
}

run :: proc(wait: proc(seconds: f32)) -> string {
  out: strings.Builder
  a: audio.Audio
  if !audio.init(&a) do return "no audio device"
  defer audio.shutdown(&a)
  synthesize()
  beep, beep_ok := audio.sound_create(&a, tone[:], 1, RATE)
  ding, ding_ok := audio.sound_create(&a, chime[:])
  fmt.sbprintfln(&out, "tone %v, chime %v", beep_ok, ding_ok)
  for pitch in ([]f32{1, 1.25, 1.5, 2}) {
    v := audio.play(&a, beep, pitch = pitch)
    fmt.sbprintfln(&out, "note at pitch %v playing %v", pitch, audio.voice_playing(&a, v))
    wait(0.3)
  }
  audio.play(&a, ding)
  wait(0.6)
  audio.set_listener(&a, {0, 0, 0}, {0, 0, -1})
  fly := audio.play(&a, beep, loop = true, position = [3]f32{-6, 0, -1})
  for step in 0 ..= 30 {
    audio.voice_set_position(&a, fly, {-6 + f32(step) * 0.4, 0, -1})
    wait(0.05)
  }
  audio.voice_stop(&a, fly)
  fmt.sbprintfln(&out, "flyby stopped, playing %v", audio.voice_playing(&a, fly))
  audio.set_bus_volume(&a, .EFFECTS, 0.2)
  quiet := audio.play(&a, ding)
  fmt.sbprintfln(&out, "chime at bus volume 0.2 playing %v", audio.voice_playing(&a, quiet))
  wait(0.6)
  fmt.sbprintfln(&out, "chime done, playing %v", audio.voice_playing(&a, quiet))
  return strings.to_string(out)
}
