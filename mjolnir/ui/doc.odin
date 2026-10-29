// Retained 2D UI: build a tree of styled boxes and text once, edit it in place, and each tick
// update re-lays out and re-tessellates only what changed into a screen-space mesh for any
// renderer (mjolnir.stage_ui); hit tests tell what is hovered, pressed or clicked.
package ui

// Layer 2: systems
