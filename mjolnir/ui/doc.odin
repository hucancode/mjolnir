// Retained 2D layout: a tree of nodes in one flat pool, laid out by flex
// rows and columns, anchors, text wrapping, clipping and scrolling, plus hit
// testing. ui draws nothing: the application turns rects and text lines
// into whatever its renderer draws (render's 2D overlay commands, say).
// Entry points: init, create, layout, update_input; the passes are in layout.odin.
package ui
