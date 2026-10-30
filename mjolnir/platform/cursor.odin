package platform

// CursorMode is how the cursor behaves over the window. LOCKED hides it and keeps it in the
// window for mouse look: the cursor position then moves without bound.
CursorMode :: enum u8 {
  NORMAL,
  HIDDEN,
  LOCKED,
}
