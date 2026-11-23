# Roadmap — vir v1 (mirrors tracking issue)

v0.1.0 tagged 2026-11-23: all Part 2 milestones plus every post-v1 item below.

## Part 1 — vlang/v readiness (PRs from fork)
- [ ] A1 IR surface: spec, version const, `ir_text.v`, round-trips
  (PR vlang/v#32555 open; findings fixed in 8124eec, re-review requested 2026-11-20)
- [x] A2 pass manager, byte-identical pipeline
  (PR vlang/v#32560 integrated into dev as 8d7431935)
- [ ] B1 V-ABI separation (post-1.0)
- [ ] B2 MIR amd64/riscv64 + SysV/Win64 (post-1.0)
- [ ] B3 object writer: COFF + MachO (post-1.0)

## Part 2 — vir
- [x] M0 bootstrap: repo, v.mod, spec draft, `virc --version`
- [x] M1 `.vir` parser/printer + verifier + `vir-verify` on corpus;
  `virc opt` runs the vendored pass manager
- [x] M2 pass manager goldens + `vir-opt` determinism proofs
  (15 frozen outputs; repeated runs byte-identical)
- [x] M2 pass manager + passes + `vir-opt`
- [x] M3 targets + ABIs + ISel + regalloc
- [x] M4 emitters + objects + `virc` (hello-world exe x3 OSes)
  (ELF/COFF exes run and differential-tested; MachO exe link-validated with lld,
  not executable on this host)
- [x] M5 `libvir` + `vir.h` (pure-C end-to-end)
- [x] M6 V dogfood + C-minus frontend vs gcc/clang
  (C-minus vs gcc and V subset vs the stock V compiler both differential-tested)
- [x] M7 fuzz + differential + benchmarks

Post-v1 remaining: nothing. vir v1 is complete.
- [x] JIT: in-process execution on Windows/amd64 (internal calls, no externals)
- [x] riscv64: RV64I emitter + ELF objects, QEMU-validated (`v run tools/riscv_diff.v`)
- [x] DWARF: compile-unit/subprogram DIEs, line tables, parameter variables and
  location lists in ELF objects (in-memory frontend path; `.vir`/bitcode carry
  no lines and no variable names)
- [x] binary bitcode: v1 SSA-core encode/decode, byte-identical round-trip
