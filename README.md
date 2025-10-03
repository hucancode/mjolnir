# Mjolnir Engine

Mjolnir is a minimalistic rendering engine. The goal is to create a simple set of tools to help people quickly create fast graphical applications

[![Logic Tests](https://github.com/hucancode/mjolnir/actions/workflows/logic-test.yml/badge.svg)](https://github.com/hucancode/mjolnir/actions/workflows/logic-test.yml)
[![Graphics Tests](https://github.com/hucancode/mjolnir/actions/workflows/visual-test.yml/badge.svg)](https://github.com/hucancode/mjolnir/actions/workflows/visual-test.yml)

![](./readme/render-target.png)

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

# Disclaimer

This is a project under active development. It is not yet stable, may contain bugs or incomplete features
