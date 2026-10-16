// Retained 2D layout: a tree of nodes laid out by flex rows and columns, anchors, text
// wrapping, clipping and scrolling, plus hit testing. ui draws nothing: the application turns
// rects and text lines into whatever its renderer draws (render's 2D overlay, say).
// Each tick: update_input, then layout, then read rect, clip and lines.
package ui

// The layout passes are in layout.odin, hit testing and focus in input.odin.
