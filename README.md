# vir — a V-native LLVM rival

Simple SSA compiler backend written in V, with a stable C API.
QBE-sized ambition: a large share of practical performance in a small,
hackable, single-language codebase — with C bindings from day one.

Status: M0 bootstrap. See `ROADMAP.md` for milestones and
`doc/ir-spec.md` for the frozen IR grammar (v1).

## Layout
- `main.v` — `virc` driver stub (M4 will grow it into the full driver)
- `doc/ir-spec.md` — versioned IR spec, the stable interface
- `ROADMAP.md` — milestone tracker (mirrors the tracking issue)
- `v.mod` — V module metadata

## Part 1 (upstream readiness)
Tracked in the same central issue; implemented as PRs from the V fork.
`vir` vendors the stabilized core with a provenance file (M0 exit).

## Build
Requires a stock V compiler on PATH. M0 only checks the stub builds.
