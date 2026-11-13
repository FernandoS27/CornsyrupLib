# CornSyrup C library

Converts Warcraft III: Reforged `.pkb` and Diablo II: Resurrected `.particles` effects into
CornSyrup (CFX) source bundles, and compiles them back. The full API is documented in
[include/cornsyrup.h](include/cornsyrup.h).

```c
#include <cornsyrup.h>

cornsyrup_decompile("effect.pkb", "effect.cfxb");   /* .pkb/.particles -> CFX bundle */
cornsyrup_build("effect.cfxb", "effect.pkb");       /* CFX bundle -> .pkb/.particles */
```

Each call returns a `CsStatus` (`CS_OK` on success); `cornsyrup_last_error` gives the reason for a
failure. There are also in-memory variants (`_mem`) and access to the CFX syntax tree as JSON
(`cornsyrup_parse`, schema in `include/cfx-ast.schema.json`).

## Contents

```text
include/                  cornsyrup.h and the CFX syntax tree's JSON Schema
lib/<os>-<arch>/          prebuilt libraries: windows, linux, macos (x86_64, arm64), wasi-wasm32
cfxlib/                   the CFX standard library the conversions read
*.cmake, CMakeLists.txt   CMake package
```

## Building with CMake

```cmake
find_package(cornsyrup 1.5 CONFIG REQUIRED)   # or: add_subdirectory(path/to/cornsyrup)

add_executable(app main.c)
target_link_libraries(app PRIVATE cornsyrup::cornsyrup)
cornsyrup_copy_runtime(app)                   # copies the library and cfxlib/ beside app
```

The right `lib/` folder is picked for your target; override it with `-DCORNSYRUP_PLATFORM=<folder>`.
Only 64-bit targets are supported. Use `cornsyrup_install_runtime(DESTINATION bin)` to install the
runtime files.

## Building without CMake

```text
cl /I include main.c lib\windows-x86_64\cornsyrup.lib                          (Windows)
cc -I include main.c -L lib/linux-x86_64 -lcornsyrup -Wl,-rpath,'$ORIGIN'       (Linux)
cc -I include main.c -L lib/macos-arm64 -lcornsyrup -Wl,-rpath,@loader_path    (macOS)
```

## Deploying

Ship the library next to your executable with the `cfxlib/` folder beside it (or point
`CsOptions.library` elsewhere). Windows and macOS need nothing installed; Linux needs glibc 2.34+
(musl distributions such as Alpine are not supported).

## WebAssembly

`lib/wasi-wasm32/` targets WASI preview 1 and has the standard library built in, so no `cfxlib/`
is needed:

- `libcornsyrup.a` — link into a C program built with wasi-sdk. Give it a larger stack, first in
  memory: `-Wl,--stack-first -Wl,-z,stack-size=1048576` (the CMake package does this).
- `cornsyrup.wasm` — a standalone module for Node, browsers, or any WASI runtime. It exports the
  API plus `memory`, `malloc` and `free`.

File-based calls only see folders the runtime grants; the `_mem` calls need no filesystem.

## License

MIT — see [LICENSE](LICENSE).
