package gui

UICommand :: union {
    UICommand_Rect,
    UICommand_Text,
    UICommand_AtlasImage,
    UICommand_Clip,
}

UICommand_Rect :: struct {
    rect: [4]f32,
    color: [4]f32,
}

UICommand_Text :: struct {
    text: string,
    position: [2]f32,
    font_id: u32,
    font_size: f32,
    color: [4]f32,
}

UICommand_AtlasImage :: struct {
    rect: [4]f32,
    atlas_region: UIAtlasRegion,
    color: [4]f32,
}

UICommand_Clip :: struct {
    rect: [4]f32,
    enable: bool,
}

UIAtlasRegion :: struct {
    uv: [4]f32,
}

CommandBuffer :: struct {
    commands: [dynamic]UICommand,
    generation_id: u64,
}

command_buffer_init :: proc(buffer: ^CommandBuffer) {
    buffer.commands = make([dynamic]UICommand, 0, 1024)
    buffer.generation_id = 0
}

command_buffer_clear :: proc(buffer: ^CommandBuffer) {
    clear(&buffer.commands)
    buffer.generation_id += 1
}

command_buffer_add :: proc(buffer: ^CommandBuffer, command: UICommand) {
    append(&buffer.commands, command)
}

command_buffer_destroy :: proc(buffer: ^CommandBuffer) {
    delete(buffer.commands)
}