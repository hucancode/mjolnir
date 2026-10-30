package audio

import "../containers"

// MAX_SOUNDS is how many sounds an Audio holds at once.
MAX_SOUNDS :: #config(AUDIO_MAX_SOUNDS, 256)
// MAX_VOICES is how many voices play at once; play fails past it.
MAX_VOICES :: #config(AUDIO_MAX_VOICES, 64)

// Sound is a sound ready to play: decoded audio created by sound_create. 0 is none.
Sound :: distinct u32

// Voice is a generational handle to one playing of a sound; stale once the voice ends.
Voice :: distinct containers.Handle

// Bus is a group of voices sharing a volume, under the master volume.
Bus :: enum u8 {
  EFFECTS,
  MUSIC,
  DIALOG,
  UI,
}

// destroy frees a sound, as sound_destroy does.
destroy :: proc {
  sound_destroy,
}
