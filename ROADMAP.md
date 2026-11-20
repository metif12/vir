# Roadmap — vir v1 (mirrors tracking issue)

## Part 1 — vlang/v readiness (PRs from fork)
- [ ] A1 IR surface: spec, version const, `ir_text.v`, round-trips
  (PR vlang/v#32555 open; review findings fixed in 8124eec, awaiting re-review)
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

Post-v1: JIT, DWARF, riscv64, binary bitcode.
