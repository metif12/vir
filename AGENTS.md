# AGENTS.md — vir

V-native SSA compiler backend. Stock **V 0.5.2** on PATH is required.

## Build / test

- Build driver: `v -o virc.exe main.v`
- Low-memory builds (Windows): `$env:VJOBS='1'` with a private TMPDIR and
  `v -memory-limit 700 ...` — full parallel builds OOM on ~15 GB hosts.
- All tests: `v test .` — serial; takes minutes, run it whole before landing.
- Single test: `v -memory-limit 700 test <path/to/*_test.v>`
- `libvir` tests **require** the flag: `v -enable-globals test libvir/libvir_test.v`
  (plain `v test .` fails on that file; that failure is expected, not a regression).
- Before every commit: `v fmt -w` each touched `.v` file, then `v fmt -l` must be
  clean and `git diff --check` must be clean.

## Architecture (non-obvious)

- `main.v` (`virc`) is a thin driver; `compile` delegates to
  `pipeline/compile_module` — `pipeline/` is the single lowering shared by
  `virc` and `libvir`. Fix lowering there, not in callers.
- `vssa/` is **vendored upstream** (see `PROVENANCE.md`): IR core + text format
  + optimizer. Do not hand-edit; re-vendor per the sync policy and keep the
  `import vssa.ssa` rewrite. `vir_smoke_test.v` is the drift guard.
- `doc/ir-spec.md` is the frozen v1 grammar — the stable interface. Change it
  only with a version bump, not as a side effect.
- `cminus/` and `vmini/` share one AST/codegen (`cminus.generate`); `vmini`
  is only a parser over it.
- `bitcode/` v1 encodes the SSA core only; `encode` rejects globals and inline
  asm by design — don't "fix" the rejection, extend the format version instead.
- `jit/` runs Windows/amd64 only and rejects external symbols by design;
  execution happens in-process, there is no object file to inspect.
- riscv64 objects need ELF flags `0x5` (toolchain match) and **static** linking
  for QEMU (`qemu-riscv64` has no dynamic loader); validate with
  `v run tools/riscv_diff.v`, which compares against cross-gcc exit codes.
- `tools/*.v` run via `v run tools/<name>.v`. `cminus_diff`, `fuzz_diff`,
  `vmini_diff` need WSL with gcc; `coff_diff` runs native Windows exes;
  MachO output is link-validated only (`lld -flavor darwin`), it cannot execute
  on this host.
- `tools/vir_opt_golden.v` deliberately rewrites `testdata/golden/` baselines;
  never run it as a check — `corpus_golden_test.v` asserts the frozen outputs.

## V 0.5.2 quirks hit here

- `fn main() int` is rejected: `fn main()` + `exit(n)`.
- `os.exec_opt` errors on nonzero child exit; use `os.exec` when the exit code
  is test data (differential harnesses).
- Number-to-enum casts need `unsafe { ... }`.
- `__global` state needs `-enable-globals` on every build/test command that
  touches it (`libvir`).
- Windows DLL: `v -cc gcc -enable-globals -shared -o vir.dll libvir/libvir.v`,
  then `dlltool -d libvir/vir.def -D vir.dll -l libvir.a` before linking
  `capi_test.c` — linking the DLL directly imports the wrong name.
