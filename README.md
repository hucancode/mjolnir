# Mjolnir Engine

Mjolnir is a minimalistic game engine to help people enjoy game programming.
* Disclaimer: this is a project under active development, it may contain bugs and surprise

[![Logic Tests](https://github.com/hucancode/mjolnir/actions/workflows/logic-test.yml/badge.svg)](https://github.com/hucancode/mjolnir/actions/workflows/logic-test.yml)
[![Graphics Tests](https://github.com/hucancode/mjolnir/actions/workflows/graphics-test.yml/badge.svg)](https://github.com/hucancode/mjolnir/actions/workflows/graphics-test.yml)

![](./readme/4-more-shader.png)

# Get Started
To use Mjolnir in your odin code, run `make shader` to compile the Slang shaders to SPIR-V (the `.spv` files are generated, not committed; it needs `slangc` from the Vulkan SDK) and then copy `mjolnir` directory to your project and start using mjolnir API.
Run `make shader-wgpu` and build with `-define:RENDER_BACKEND=wgpu` for the WebGPU backend, and `make web EXAMPLE=<name>` for the browser.
See `examples` for common use cases, and [document](https://hucancode.github.io/mjolnir) for more informations.

# Notable features

- GLTF, Skinning, Physically-Based Rendering, Post-processing
- Render to texture
- Vulkan, WebGPU
- Animation, IK, Procedural Animation (Tail, Leg), Spline
- Sprite, HUD, Overlay
- Particles Simulation
- Physics
- Recast/Detour
- Behavior Tree, Finite State Machine
- General Purpose GPU (WIP)
