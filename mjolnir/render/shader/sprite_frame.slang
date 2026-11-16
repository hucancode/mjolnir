// The frame a sprite node shows, for shaders that declare `sprite_frames` (the sprite frame
// table) before including this: its material's set at the node's frame (render wraps it to the
// set), or the whole texture at size 1 when the material has none.
SpriteFrame sprite_frame_of(Material material, Node node)
{
    if (material.sprite_frames == 0) {
        SpriteFrame whole;
        whole.uv[0] = float2(0, 0);
        whole.uv[1] = float2(1, 0);
        whole.uv[2] = float2(1, 1);
        whole.uv[3] = float2(0, 1);
        whole.offset = float2(0, 0);
        whole.size = float2(1, 1);
        return whole;
    }
    return sprite_frames[material.sprite_frames - 1 + node.frame];
}
