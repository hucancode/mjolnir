# Mjolnir Engine

Mjolnir is a minimalistic game engine to help people enjoy game programming.
* Disclaimer: this is a project under active development, it may contain bugs and surprise

[![Logic Tests](https://github.com/hucancode/mjolnir/actions/workflows/logic-test.yml/badge.svg)](https://github.com/hucancode/mjolnir/actions/workflows/logic-test.yml)
[![Graphics Tests](https://github.com/hucancode/mjolnir/actions/workflows/visual-test.yml/badge.svg)](https://github.com/hucancode/mjolnir/actions/workflows/visual-test.yml)

![](./readme/lights.png)

# Get Started
To use Mjolnir in your odin code, run `make shader` to compile shaders to SPIR-V and then copy `mjolnir` directory to your project and start using mjolnir API.
See `examples` for common use cases.

# Notable features

- Physically-Based Rendering
- Camera, Light, Shadow
- Skinning, Animation
- GLTF
- Post-processing
- Billboard, Sprite
- Tween, Spline
- Particles Simulation
- Render to texture
- Physics
- Recast/Detour
- Inverse Kinematics
- HUD, text

And more in development

- Procedural Animation (Tail, Leg)
- Animation Layering

## Build Commands

```bash
# Build and run in release mode
make run
# Build and run in debug mode and vulkan validation
make debug
# Build only (release mode)
make build
# Build only (debug mode)
make build-debug
# Build all shaders
make shader
# Run all tests
odin test . --all-packages
# run a single test called "test_name" inside "module_name"
odin test . --all-packages -define:ODIN_TEST_NAMES=module_name.test_name
```
