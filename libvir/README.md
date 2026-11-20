# libvir — the vir C API (M5)

`libvir` exposes the vir compiler as a C shared library. A C frontend drives
the whole pipeline through `vir.h` without linking the V runtime:

    vir_parse -> vir_optimize -> vir_verify -> vir_compile -> vir_module_free

The ABI version is `VIR_ABI_VERSION` (currently 1), versioned separately from
the `.vir` grammar. `vir_abi_version()` returns it at runtime.

## API

See `vir.h` for the authoritative declarations. All string inputs are
NUL-terminated C strings; `vir_last_error()` returns a description of the last
failure (valid until the next libvir call). Module handles are opaque
`VirModule` values: a non-NULL handle must be released with `vir_module_free`.

`vir_compile` lowers a module to an ELF64 relocatable object for the given
triple. In v1 only `amd64-*` targets are supported; full executable linking is
still pending.

## Build

From the repository root (a stock V compiler is required). Globals are used
for the module registry, so `-enable-globals` is mandatory:

    # Windows
    v -cc gcc -enable-globals -shared -o vir.dll libvir/libvir.v

    # Linux / macOS
    v -enable-globals -shared -o libvir.so libvir/libvir.v

The exported symbols are `vir_abi_version`, `vir_parse`, `vir_optimize`,
`vir_verify`, `vir_compile`, `vir_last_error` and `vir_module_free`.

On Windows, V 0.5.2 bakes `out.exe` as the DLL's internal export name, so
linking C directly against `vir.dll` imports from the wrong name. Use the
supplied `vir.def` to build a correct import library:

    dlltool -d libvir\vir.def -D vir.dll -l libvir.a
    gcc -Ilibvir libvir\capi_test.c libvir.a -o capi_test.exe

Keep `vir.dll` next to `capi_test.exe` when running it.

## End-to-end C check

`capi_test.c` is a pure-C program that parses a `.vir` module, optimizes and
verifies it, compiles it to an object, and checks the ELF magic — using only
`vir.h`:

    capi_test out.o

Expected output: `capi_test: ok (abi=1, elf=7f454c46)`.

The V-side tests in `libvir_test.v` exercise the same ABI entry points
directly, including the error paths. They require `-enable-globals`:

    v -enable-globals test libvir/libvir_test.v
