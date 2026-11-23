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
- `main.v` — `virc` driver: `--version`, `verify <file.vir>`,
  `opt <file.vir> [out.vir]`
- `vssa/` — vendored stabilized V compiler middle-end (see
  `PROVENANCE.md`): `ssa/` (IR + text format), `optimize/` (passes,
  pass manager, verifiers)
- `target/` — triple/ABI model
- `mach/` — machine IR, ISel, linear-scan regalloc
- `emit/` — amd64 emitter
- `obj/` — ELF64, Windows/amd64 COFF and macOS/amd64 MachO object writers
- `dwarf/` — minimal DWARF 4 producer (compile unit + subprogram DIEs + line table)
- `bitcode/` — binary IR v1 encoder/decoder for the SSA core
- `pipeline/` — lowering pipeline shared by `virc` and `libvir`
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
emits an ELF64 object for `amd64-linux-gnu`, a COFF object for
`amd64-windows-msvc`, or a MachO object for `amd64-macos-darwin`. The first
two link and run with gcc; the MachO object links with `lld -flavor darwin`
but cannot be executed on this host. ELF objects carry DWARF 4 compile-unit,
subprogram and line-table info, verifiable with `llvm-dwarfdump`. Line rows
exist only for modules compiled from a frontend AST in memory (`generate_with_lines`
+ `compile_module_lines`): `.vir` text and bitcode v1 carry no source lines, so
file-path objects get a valid but empty line program.
`virc cminus <in.c> [out.vir]` runs the C-minus frontend; `virc vmini <in.v>
[out.vir]` runs the V-subset frontend. `virc bitcode encode <in.vir> <out.vbc>`
and `virc bitcode decode <in.vbc> [out.vir]` convert between text IR and the
v1 binary format (round-trips are byte-identical; globals and inline asm are
out of scope).
See `libvir/README.md` to build the C shared library, and run
`v run tools/cminus_diff.v` to compare vir-compiled fixtures against gcc
(requires WSL with gcc); `v run tools/coff_diff.v` does the same with native
Windows executables; `v run tools/vmini_diff.v` compares V-subset programs
against the stock V compiler. `v run tools/fuzz_diff.v [n] [seed]` fuzzes
random programs through the Linux differential, and `v run tools/bench.v`
reports compile times and object sizes. `v run tools/vir_opt_determinism.v`
proves `virc opt` is byte-identical across repeated runs.
