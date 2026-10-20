// No effect: copies the input.
struct Effect { uint _unused; }
#include "post.slang"

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    return post_input(v.uv);
}
