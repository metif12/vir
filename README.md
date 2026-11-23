# vir — a V-native LLVM rival

Simple SSA compiler backend written in V, with a stable C API.
QBE-sized ambition: a large share of practical performance in a small,
hackable, single-language codebase — with C bindings from day one.

Status: all Part 2 milestones M0-M7 complete. M4 produces executables for Linux (ELF),
Windows (COFF) and macOS (MachO) — the first two are run and differential-
tested, the MachO output is link-validated but cannot run on this host. Both
frontends (C-minus and the V subset) are differentially tested against gcc
and the stock V compiler respectively. See `ROADMAP.md` for milestones and
`doc/ir-spec.md` for the frozen IR grammar (v1).

## Layout
- `main.v` — `virc` driver: `--version`, `verify`/`opt`/`compile`,
  `cminus`/`vmini` frontends, `jit` runner, `bitcode` converter
- `vssa/` — vendored stabilized V compiler middle-end (see
  `PROVENANCE.md`): `ssa/` (IR + text format), `optimize/` (passes,
  pass manager, verifiers)
- `target/` — triple/ABI model
- `mach/` — machine IR, ISel, linear-scan regalloc
- `emit/` — amd64 and RV64I emitters (+ `riscv64_test.v` encoding goldens)
- `obj/` — ELF64, Windows/amd64 COFF and macOS/amd64 MachO object writers
- `dwarf/` — minimal DWARF 4 producer (unit + subprograms + line table + parameter variables)
- `bitcode/` — binary IR v1 encoder/decoder for the SSA core
- `jit/` — in-process JIT executor (Windows/amd64 v1, no externals)
- `pipeline/` — lowering pipeline shared by `virc` and `libvir`
  (`compile_module` for objects, `lower_module` for the JIT)
- `libvir/` — C shared library, `vir.h`, and a pure-C end-to-end test
- `cminus/` — C-minus frontend (lexer, parser, AST -> `ssa.Module`)
- `vmini/` — V-subset frontend for dogfooding (reuses the cminus AST/codegen)
- `testdata/` — golden `.vir` corpus (`smoke.vir`), C-minus fixtures (including
  four fuzz-found regressions), V-subset fixtures and `golden/` optimizer baselines
- `corpus_golden_test.v` — frozen pass-manager output tests
- `fuzz_test.v` — seeded IR text round-trip/verifier property test
- `tools/cminus_diff.v` — Linux differential runner (vir vs gcc)
- `tools/coff_diff.v` — Windows differential runner via native .exe files
- `tools/vmini_diff.v` — V dogfood differential: vir vs the stock V compiler
- `tools/riscv_diff.v` — riscv64 differential: vir vs cross-gcc under QEMU (V-subset via JIT oracle)
- `tools/vir_opt_golden.v` — deliberately regenerate the optimizer golden files
- `tools/vir_opt_determinism.v` — repeated-run byte-identity check
- `tools/fuzz_diff.v` — seeded random-program differential fuzzer
- `tools/bench.v` — vir vs gcc compile-time and object-size microbenchmarks
- `vir_smoke_test.v`, `corpus_test.v` — vendoring guards: build,
  optimize, verify, round-trip
- `compile_test.v` — end-to-end compile-to-ELF-object tests
- `doc/ir-spec.md` — versioned IR spec, the stable interface
- `doc/machine-ir.md` — machine IR / lowering notes
- `ROADMAP.md` — milestone tracker (mirrors the tracking issue)
- `v.mod` — V module metadata

## Part 1 (upstream readiness)
Tracked in the same central issue; implemented as PRs from the V fork.
`vir` vendors the stabilized core with a provenance file (M0 exit).

## Build
Requires a stock V compiler on PATH. `virc compile <in.vir> <out.o> [triple]`
emits an ELF64 object for `amd64-linux-gnu` or `riscv64-linux-gnu`, a COFF object for
`amd64-windows-msvc`, or a MachO object for `amd64-macos-darwin`. The first
two link and run with gcc; the MachO object links with `lld -flavor darwin`
but cannot be executed on this host. ELF objects carry DWARF 4 compile-unit,
subprogram, line-table, parameter-variable and location-list info, verifiable
with `llvm-dwarfdump` and `readelf --debug-dump`. Line rows exist only for
modules compiled from a frontend AST in memory (`generate_with_lines` +
`compile_module_lines`): `.vir` text and bitcode v1 carry no source lines, so
file-path objects get a valid but empty line program. Variable entries
describe parameters at their entry locations and tracked locals with address
ranges (`compile_module_debug` + `generate_with_debug`); constants and
optimizer-created values have no entries.
`virc cminus <in.c> [out.vir]` runs the C-minus frontend; `virc vmini <in.v>
[out.vir]` runs the V-subset frontend. `virc bitcode encode <in.vir> <out.vbc>`
and `virc bitcode decode <in.vbc> [out.vir]` convert between text IR and the
v1 binary format (round-trips are byte-identical; globals and inline asm are
out of scope). `virc jit <in.c|in.v>` runs a C-minus or V-subset program
in-process without writing an object file (Windows/amd64 v1, no externals).
See `libvir/README.md` to build the C shared library, and run
`v run tools/cminus_diff.v` to compare vir-compiled fixtures against gcc
(requires WSL with gcc); `v run tools/coff_diff.v` does the same with native
Windows executables; `v run tools/vmini_diff.v` compares V-subset programs
against the stock V compiler. `v run tools/riscv_diff.v` compares riscv64
fixtures against the cross gcc under `qemu-riscv64` (requires the cross
toolchain in WSL), using the in-process JIT as oracle for the V-subset
fixtures. `v run tools/fuzz_diff.v [n] [seed]` fuzzes
random programs through the Linux differential, and `v run tools/bench.v`
reports compile times and object sizes. `v run tools/vir_opt_determinism.v`
proves `virc opt` is byte-identical across repeated runs.
