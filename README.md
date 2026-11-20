# vir — a V-native LLVM rival

Simple SSA compiler backend written in V, with a stable C API.
QBE-sized ambition: a large share of practical performance in a small,
hackable, single-language codebase — with C bindings from day one.

Status: M3/M5/M7 complete; M4 ELF object emission via `virc` and `libvir`
landed (cross-OS executables pending); M6 C-minus frontend + gcc differential
landed (V dogfood pending). See `ROADMAP.md` for milestones and
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
- `obj/` — ELF64 object writer
- `pipeline/` — lowering pipeline shared by `virc` and `libvir`
- `libvir/` — C shared library, `vir.h`, and a pure-C end-to-end test
- `cminus/` — C-minus frontend (lexer, parser, AST -> `ssa.Module`)
- `testdata/` — golden `.vir` corpus (`smoke.vir`) and C-minus fixtures,
  including four differential regressions found by the fuzzer
- `fuzz_test.v` — seeded IR text round-trip/verifier property test
- `tools/cminus_diff.v` — differential runner: vir vs gcc on the fixtures
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
emits an ELF64 object for amd64-linux-gnu; full executable linking is
still pending. `virc cminus <in.c> [out.vir]` runs the C-minus frontend.
See `libvir/README.md` to build the C shared library, and run
`v run tools/cminus_diff.v` to compare vir-compiled fixtures against gcc
(requires WSL with gcc). `v run tools/fuzz_diff.v [n] [seed]` fuzzes random
programs through the same differential, and `v run tools/bench.v` reports
compile times and object sizes.
