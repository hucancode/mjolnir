# Mjolnir Engine

Mjolnir is a minimalistic game engine. Implementation will prefer simplicity over fancy features. The goal is to create a simple set of tools to help people enjoy game programming

[![Logic Tests](https://github.com/hucancode/mjolnir/actions/workflows/logic-test.yml/badge.svg)](https://github.com/hucancode/mjolnir/actions/workflows/logic-test.yml)
[![Graphics Tests](https://github.com/hucancode/mjolnir/actions/workflows/visual-test.yml/badge.svg)](https://github.com/hucancode/mjolnir/actions/workflows/visual-test.yml)

![](./readme/lights.png)

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

## WIP

- Physics
- Recast/Detour
- UI, fonts
- Inverse Kinematics
- Procedural Animation (Tail, Leg)
- Animation Layering
- Level Manager

# Build scripts
```sh
make build # build the project in release mode without running
make run # build and run the project in release mode
make debug # build and run the project in debug mode
make test # run the tests
make clean # clean the build artifacts
make check # check for compiler errors without building
make shader # build all shaders
```

# Disclaimer

This is a project under active development ([roadmap](https://notes.hucanco.de/mjolnir)). It is not yet stable, may contain bugs or incomplete features
