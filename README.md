# Mjolnir Engine

Mjolnir is a minimalistic rendering engine. The goal is to create a simple set of tools to help people quickly create fast graphical applications

[![Run Tests](https://github.com/hucancode/mjolnir/actions/workflows/test.yml/badge.svg)](https://github.com/hucancode/mjolnir/actions/workflows/test.yml)

![](./readme/pbr-cross-hatching.png)

# Work in Progress

- Render To Texture

## To do

- Parallel rendering / GPU Indirect Drawing

# Disclaimer

This is a project under active development. It is not yet stable, may contain bugs or incomplete features

# Build scripts
```sh
make build # build the project in release mode without running
make run # build and run the project in release mode
make debug # build and run the project in debug mode
make test # run the tests
make clean # clean the build artifacts
make check # check for compiler errors without building
make shader # build all shaders
make mjolnir/shader/{shader_name}/vert.spv # build a specific vertex shader, use frag.spv for fragment shader
```
