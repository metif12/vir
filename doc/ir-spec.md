# vir IR spec — v1 (frozen grammar draft, M0)

The text format is the stable interface. Frontends emit `.vir` text or
drive `libvir`; backends consume it. Text round-trips byte-identical.

## 1. Identifiers
- Types: `%tN` (e.g. `%t0` = word). Values: `%vN`. Blocks: `@bN`.
- Globals: `$name`. Functions: `$name`. Sigils mirror QBE conventions.

## 2. Types (v1 core, machine-grounded)
`w` word u32, `l` long u64, `s`/`d` f32/f64, `b`/`h` u8/u16 (data only),
`ptr<T>`, `struct_t { ... }` (ordered fields, explicit padding),
fixed arrays `[N x T]`. No sum/option/interface: guests lower to
structs + discriminant + calls (dogfood proves this in M6).

## 3. Module
`vir 1; target <triple>;` then data, declarations, function definitions
in SSA with explicit `phi` nodes. Capabilities line declares optional
extensions (none in v1 core).

## 4. Opcodes (v1 core subset)
Terminators: `ret br jmp switch unreachable`. Integer: `add sub mul
sdiv srem udiv urem`. Float: `fadd fsub fmul fdiv frem`. Bitwise:
`shl ashr lshr and or xor not`. Memory: `alloca load store gep fence`.
Compare: full int/float set. Other: `call call_indirect cast phi
select`. Everything else (atomics, vectors, concurrency) is post-v1.

## 5. Versioning
`vir <N>` header pins the grammar. Parsers reject newer majors.
C API versioned separately by semver (see ROADMAP M5).

## Provenance
Seeded from V `vlib/v/ssa/ssa.v` (63 ops) minus V-coupled ops
(`inline_string_init`, `go_call`, `spawn_call`) and V runtime layouts.
Vendoring happens at M0 exit with exact commit recorded here.
