# Machine IR and instruction selection (M3)

`vir/target` owns triples and calling conventions. `vir/mach` owns the
machine IR and the amd64 selector. arm64 selector, assembler emission,
and the register allocator build on these shapes.

## Target triple

`arch-os-abi`, e.g. `amd64-linux-gnu`, `amd64-windows-msvc`,
`aarch64-macos-aapcs64`. Aliases: `x86_64` -> `amd64`,
`aarch64` -> `arm64`, `macosx` -> `macos`, `win32`/`win64` ->
`windows`. v1 arches: `amd64`, `arm64`. Anything else is a clean
parse error (riscv64 is explicitly post-v1).

## Calling conventions (data, not code)

- SysV AMD64: int args `rdi rsi rdx rcx r8 r9`, float args
  `xmm0-7`, return `rax` (+`rdx` for 128-bit); stack slots 8 bytes;
  16-byte stack alignment; 128-byte red zone (leaf functions only).
- Win64: first four args `rcx rdx r8 r9` / `xmm0-3` (shared slots by
  position), rest on stack; caller reserves 32 bytes of shadow space;
  return `rax`; no red zone; 16-byte alignment.
- AAPCS64: int args `x0-x7`, float args `v0-v7` (separate banks);
  return `x0` (+`x1`); 16-byte alignment.

`assign_args` maps an argument-kind list to registers or stack offsets.
Variadics and 128-bit returns are rejected for now.

## Machine IR

One function = blocks of machine instructions over virtual registers.
An instruction is `op dst, srcs...` where an operand is a virtual reg,
a physical reg, an immediate, a stack slot, a memory reference
(base + displacement), or a symbol. amd64 v1 ops: `mov`, `movi`,
`add`, `sub`, `imul`, `neg`, `cmp`, `setcc`, `jmp`, `jcc`, `call`,
`ret`, `load`, `store`. No register constraints yet: every SSA value gets a
fresh virtual register, and every operand stays in virtual form. The
register allocator (next) rewrites virtuals to physicals and stack
slots; the naive fallback (every vreg is a stack slot) is always
available and always correct.

## Selector contract (amd64, integer subset)

Input: verified SSA with phis eliminated (run the default pipeline
first; the selector errors on `phi`). Constants become `movi`;
`add`/`sub`/`mul` become `mov` + the op; comparisons + branches become
`cmp` + `setcc`/`jcc`/`jmp`; `ret` moves to `rax`; calls move arguments
per the convention and emit `call`; phi elimination `assign` copies
become `mov`. Types other than 1/2/4/8-byte ints and pointers are
rejected with a clear error.
