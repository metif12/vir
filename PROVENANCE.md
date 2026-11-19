# vssa provenance

`vssa/` is a minimal vendored copy of the stabilized V compiler middle-end.
It is the only part of `vir` that originates upstream. Everything else in
this repo is written for `vir`.

## What is vendored

- `vssa/ssa/ssa.v`, `vssa/ssa/ir_text.v` — IR core + text format.
- `vssa/optimize/optimize.v`, `pass.v`, `fold.v`, `dce.v`, `mem2reg.v`,
  `phi.v`, `blocks.v`, `cfg.v`, `dominators.v`, `cse.v`, `inline.v`,
  `memory.v`, `verifier.v`, `verify.v` — passes, manager, verifiers.

Deliberately excluded: `builder.v` (lowers from V's flat AST + checker,
deeply V-coupled), `native_*.v`/`worker.v` (V runtime helpers),
`driver`/`pref` (V-specific pipeline; `vir` has its own driver).

## From where

- `ssa.v`, `ir_text.v`: `metif12/v` branch `vir-a1-ir-text`
  (upstream PR `vlang/v#32555`), commit `78ae0a9`.
- `optimize/*`: `metif12/v` branch `vir-a2-passmanager`
  (upstream PR `vlang/v#32560`), commit `c44e366d06`.
- Both branches share upstream base `986bf429cd`.

## Mechanical adaptation

- `import v.ssa` rewritten to `import vssa.ssa` in `vssa/optimize/*.v`
  (14 files). No other change: `v.token` stays stdlib.
- `ir_spec.md` (upstream `vlib/v/ssa/ir_spec.md`) informed `doc/ir-spec.md`,
  which is `vir`'s own frozen v1 grammar, not a copy.

## Sync policy

- Pin: record branch + commit above on every re-vendor.
- Sync: copy the files again, re-apply the one-line import rewrite,
  run `v test .` — the smoke test plus ported goldens must stay green.
- Goal: after the upstream PRs merge, re-vendor from `vlang/v` master
  and drop the fork branch names here.
- Drift guard: `vir_smoke_test.v` round-trips a module through
  optimize + text; any semantic drift in the vendored core breaks it.
