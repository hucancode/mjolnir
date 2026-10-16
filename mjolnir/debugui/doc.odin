// An immediate-mode debug UI (microui), the glue between input and render. init it once the
// renderer is ready; each update tick feed it the input.State first, so the widgets capture
// the mouse and keyboard they use; each frame build widgets on the context begin returns,
// then hand end's commands to render.stage_overlay (with any other overlay commands).
package debugui
