package main

import "core:math/rand"
import "mjolnir/render"

IMPACT_VERTICES :: 12
IMPACT_LIFE :: f32(1.2)
MAX_IMPACTS :: 64
SPARK_SLOTS :: 8
SPARKS :: f32(12)

Impact :: struct {
  born:     f32,
  position: [3]f32,
  color:    [3]f32,
  power:    f32,
  furious:  bool,
  sparked:  bool,
}

ImpactInstance :: struct {
  position: [3]f32,
  age:      f32,
  color:    [3]f32,
  power:    f32,
}

ImpactParams :: struct {
  first: u32,
}

impact_spawn :: proc(s: ^Storm, position, color: [3]f32, power: f32, furious: bool) {
  append(&s.impacts, Impact{born = s.time, position = position, color = color, power = power, furious = furious})
}

impact_expire :: proc(s: ^Storm) {
  for i := len(s.impacts) - 1; i >= 0; i -= 1 {
    if s.time - s.impacts[i].born > IMPACT_LIFE do unordered_remove(&s.impacts, i)
  }
}

impact_instance :: proc(s: ^Storm, i: Impact) -> ImpactInstance {
  return {position = i.position, age = s.time - i.born, color = i.color, power = i.power}
}
