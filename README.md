# Mjolnir Engine

Mjolnir is a minimalistic game engine. Implementation will prefer simplicity over fancy features. The goal is to create a simple set of tools to help people enjoy game programming

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
- Level Manager

And more in development

- UI, fonts
- Procedural Animation (Tail, Leg)
- Animation Layering
