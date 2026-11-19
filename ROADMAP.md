# Roadmap — vir v1 (mirrors tracking issue)

## Part 1 — vlang/v readiness (PRs from fork)
- [ ] A1 IR surface: spec, version const, `ir_text.v`, round-trips
- [ ] A2 pass manager, byte-identical pipeline
- [ ] B1 V-ABI separation (post-1.0)
- [ ] B2 MIR amd64/riscv64 + SysV/Win64 (post-1.0)
- [ ] B3 object writer: COFF + MachO (post-1.0)

## Part 2 — vir
- [x] M0 bootstrap: repo, v.mod, spec draft, CI to come
- [ ] M1 `.vir` parser/printer + verifier + `vir-verify`
- [ ] M2 pass manager + passes + `vir-opt`
- [ ] M3 targets + ABIs + ISel + regalloc
- [ ] M4 emitters + objects + `virc` (hello-world exe x3 OSes)
- [ ] M5 `libvir` + `vir.h` (pure-C end-to-end)
- [ ] M6 V dogfood + C-minus frontend vs gcc/clang
- [ ] M7 fuzz + differential + benchmarks

Post-v1: JIT, DWARF, riscv64, binary bitcode.
