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

## Register allocation (linear scan)

`vir/mach/regalloc.v` owns allocation; the machine IR carries it with
no format change except stack-slot operands (`[fp+N]`, bound below
the frame pointer as `[rbp-(n+1)*8]`) and `mem` operands with the
frame-pointer base: non-negative displacements address the incoming
stack-argument area (`[rbp+16+disp]` on amd64), negative displacements
address the frame itself (`[rbp+disp]`, used for spilled pointer bases).

- Pool: caller-saved registers minus the return register
  (`rcx rdx rsi rdi r8 r9 r10 r11` on amd64, `x1-x15` on arm64).
  Excluding the return register keeps fixed call/return sequences
  from ever colliding with allocated values.
- Intervals over flattened block order. Any interval strictly
  containing a call spills — arguments are consumed before the
  clobber and results produced after it, so nothing else can break.
- Linear scan with furthest-end spilling and mov-coalescing hints.
- Rewrite maps every virtual to a register or a slot; afterwards
  `assert_no_vregs` holds, which is M4's input invariant. Stack slots
  are 8 bytes; `stack_slots` on the function sizes the frame.

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

## Selector contract (amd64 + arm64, integer subset)

Input: verified SSA with phis eliminated (run the default pipeline
first; the selector errors on `phi`). One shared lowering shape covers
both arches; only registers and the calling convention change
(`MachineSelector`, dispatched by triple; `select_amd64` stays as a
convenience wrapper). Constants become `movi`; `add`/`sub`/`mul`
become `mov` + the op; comparisons + branches become `cmp` +
`setcc`/`jcc`/`jmp`; `ret` moves to `rax`/`x0`; calls move arguments
per the convention and emit `call`; phi elimination `assign` copies
become `mov`. Types other than 1/2/4/8-byte ints and pointers are
rejected with a clear error. Wide immediates and frame binding are
the emitter's job (M4), not the selector's.
