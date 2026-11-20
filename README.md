# vir — a V-native LLVM rival

Simple SSA compiler backend written in V, with a stable C API.
QBE-sized ambition: a large share of practical performance in a small,
hackable, single-language codebase — with C bindings from day one.

Status: M3 complete; M4 emitters + ELF objects landed, virc object
emission in progress. See `ROADMAP.md` for milestones and
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
- `testdata/` — golden `.vir` corpus (`smoke.vir`)
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
still pending.
