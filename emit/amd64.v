module emit

import mach
import target

// r_x86_64_pc32 is the ELF x86-64 relocation type for a 32-bit PC-relative
// reference (S + A - P), used for rip-relative symbol addresses.
pub const r_x86_64_pc32 = 2

// r_x86_64_plt32 is the ELF x86-64 relocation type for a 32-bit PLT call
// reference (S + A - P), used for every call, internal or external.
pub const r_x86_64_plt32 = 4

// EmitSym is one symbol-table entry for the object writer. Defined functions
// carry their text offset and byte size; call targets and symbol references
// start undefined and are resolved by the linker. All symbols are global.
pub struct EmitSym {
pub mut:
	name         string
	is_func      bool
	offset       u32
	size         u32
	is_undefined bool
}

// EmitReloc is one relocation against the text section: offset is the byte
// position of the 32-bit field to patch, sym indexes EmitOutput.syms, typ is
// r_x86_64_pc32 or r_x86_64_plt32, and addend is the ELF Rela addend.
pub struct EmitReloc {
pub mut:
	offset u32
	sym    int
	typ    int
	addend i64
}

// LineRow maps one text-section offset to its 1-based source line: the
// address side of a DWARF line-table row. Rows are section-relative, like
// EmitSym offsets, so the object writer needs no relocation for them.
pub struct LineRow {
pub mut:
	offset u32
	line   int
}

// EmitOutput is the plain-data result of emission, consumed by the object
// writer. data and rodata stay empty in v1: no globals are lowered yet.
pub struct EmitOutput {
pub mut:
	text      []u8
	data      []u8
	rodata    []u8
	syms      []EmitSym
	relocs    []EmitReloc
	line_rows []LineRow
}

// fp_vreg mirrors mach's private frame-pointer placeholder. It is only valid
// as a memory base; frame lowering binds it to rbp here.
const fp_vreg = -100

// Emitter accumulates text, symbols and relocations across all functions.
struct Emitter {
mut:
	text      []u8
	syms      []EmitSym
	sym_idx   map[string]int
	relocs    []EmitReloc
	line_rows []LineRow
	shadow    int
}

// BranchPatch records one rel32 field awaiting its target block's offset.
struct BranchPatch {
	site   int
	target int
}

// FuncCtx carries per-function layout state: the frame size in slots, the
// absolute text offset of every block, and the pending branch patches.
// `frame` is the byte size of the laid-out frame (riscv64 epilogues need it
// at every ret site; the amd64 emitter ignores it).
struct FuncCtx {
	stack_slots int
	frame       int
mut:
	block_offs map[int]int
	patches    []BranchPatch
}

// emit_amd64 encodes a register-allocated machine module into amd64 text plus
// symbols and relocations. SysV and Win64 share all encodings; Win64 adds 32
// bytes of shadow space to every frame. The module must already satisfy
// mach.assert_no_vregs: only physical registers and stack slots may remain.
pub fn emit_amd64(m &mach.MachineModule, t target.Triple) !EmitOutput {
	if t.arch != .amd64 {
		return error('vir: amd64 emitter cannot target ${t.arch}')
	}
	mach.assert_no_vregs(m)!
	cc := target.callconv_for(t)!
	mut e := Emitter{
		sym_idx: map[string]int{}
		shadow:  cc.shadow_space
	}
	for f in m.funcs {
		e.emit_func(f)!
	}
	return EmitOutput{
		text:      e.text
		syms:      e.syms
		relocs:    e.relocs
		line_rows: e.line_rows
	}
}

// emit_func lays out one function: prologue, blocks in order, branch
// back-patching, then the symbol size. Entry moves are already part of
// block 0 and are emitted as-is.
fn (mut e Emitter) emit_func(f mach.MachineFunc) ! {
	if f.blocks.len == 0 {
		return error('vir: function ${f.name} has no blocks')
	}
	func_off := e.text.len
	sym := e.sym_define(f.name, u32(func_off))
	// Frame: spill slots plus Win64 shadow space, 16-byte aligned. After
	// push rbp the stack is 16-aligned, so calls stay aligned too.
	frame := (f.stack_slots * 8 + e.shadow + 15) & ~15
	e.emit(0x55) // push rbp
	e.emit(0x48) // mov rbp, rsp
	e.emit(0x89)
	e.emit(0xE5)
	if frame > 0 {
		if frame <= 127 {
			e.emit(0x48) // sub rsp, imm8
			e.emit(0x83)
			e.emit(0xEC)
			e.emit(u8(frame))
		} else {
			e.emit(0x48) // sub rsp, imm32
			e.emit(0x81)
			e.emit(0xEC)
			e.emit_u32(u32(frame))
		}
	}
	mut ctx := FuncCtx{
		stack_slots: f.stack_slots
		block_offs:  map[int]int{}
	}
	for b in f.blocks {
		ctx.block_offs[b.id] = e.text.len
		for ins in b.instrs {
			// Record the line row before encoding: the row address is the
			// offset of the instruction's first byte. Line 0 (unknown)
			// carries no row; consecutive duplicates are merged by DWARF.
			if ins.line > 0 {
				if e.line_rows.len == 0 || e.line_rows[e.line_rows.len - 1].line != ins.line {
					e.line_rows << LineRow{ offset: u32(e.text.len), line: ins.line }
				}
			}
			e.emit_instr(ins, mut ctx)!
		}
	}
	// Second pass: every block offset is known, so patch all rel32 fields.
	for p in ctx.patches {
		target_off := ctx.block_offs[p.target] or {
			return error('vir: branch to unknown block @b${p.target} in ${f.name}')
		}
		rel := target_off - (p.site + 4)
		e.patch_u32(p.site, u32(rel))
	}
	// Guard against fall-through into the next function when the last
	// block does not end in ret or an unconditional jump.
	last := f.blocks[f.blocks.len - 1].instrs
	if last.len == 0 || (last[last.len - 1].op != .ret && last[last.len - 1].op != .jmp) {
		e.emit_epilogue()
	}
	e.syms[sym].size = u32(e.text.len - func_off)
}

// emit_instr encodes one machine instruction.
fn (mut e Emitter) emit_instr(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	match ins.op {
		.mov, .movi {
			e.emit_mov(ins, mut ctx)!
		}
		.add, .sub, .imul {
			e.emit_binop(ins, mut ctx)!
		}
		.neg {
			e.emit_neg(ins, mut ctx)!
		}
		.cmp {
			e.emit_cmp(ins, mut ctx)!
		}
		.setcc {
			e.emit_setcc(ins, mut ctx)!
		}
		.jmp, .jcc {
			e.emit_branch(ins, mut ctx)!
		}
		.call {
			e.emit_call(ins)!
		}
		.ret {
			e.emit_epilogue()
		}
		.load {
			e.emit_load(ins, mut ctx)!
		}
		.store {
			e.emit_store(ins, mut ctx)!
		}
	}
}

// emit_epilogue restores the frame and returns: mov rsp, rbp; pop rbp; ret.
// The return value must already be in rax (the selector's ret move).
fn (mut e Emitter) emit_epilogue() {
	e.emit(0x48) // mov rsp, rbp
	e.emit(0x89)
	e.emit(0xEC)
	e.emit(0x5D) // pop rbp
	e.emit(0xC3) // ret
}

// emit_mov encodes mov and movi. Register destinations take the direct
// forms; slot destinations go through rax, which the allocator never
// assigns, so it is always free as scratch.
fn (mut e Emitter) emit_mov(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if !ins.has_dst || ins.srcs.len != 1 {
		return error('vir: ${ins.op} needs one destination and one source')
	}
	src := ins.srcs[0]
	if ins.op == .movi && src.kind != .imm {
		return error('vir: movi needs an immediate source')
	}
	if ins.dst.kind == .reg {
		dst_hw := e.hw_reg(ins.dst.reg)!
		match src.kind {
			.reg {
				e.emit_reg_reg(0x89, dst_hw, e.hw_reg(src.reg)!)
			}
			.imm {
				e.emit_movi_value(dst_hw, src.imm)
			}
			.slot, .mem {
				base_hw, disp := e.mem_addr(src, ctx)!
				e.emit_reg_mem(0x8B, dst_hw, base_hw, disp)
			}
			.symbol {
				e.emit_lea_rip(dst_hw, src.symbol)
			}
		}
		return
	}
	if ins.dst.kind == .slot {
		base_hw, disp := e.mem_addr(ins.dst, ctx)!
		match src.kind {
			.reg {
				e.emit_reg_mem(0x89, e.hw_reg(src.reg)!, base_hw, disp)
			}
			.imm {
				e.emit_movi_value(0, src.imm)
				e.emit_reg_mem(0x89, 0, base_hw, disp)
			}
			.slot, .mem {
				sb, sd := e.mem_addr(src, ctx)!
				e.emit_reg_mem(0x8B, 0, sb, sd)
				e.emit_reg_mem(0x89, 0, base_hw, disp)
			}
			.symbol {
				e.emit_lea_rip(0, src.symbol)
				e.emit_reg_mem(0x89, 0, base_hw, disp)
			}
		}
		return
	}
	return error('vir: ${ins.op} destination must be a register or slot')
}

// emit_binop encodes add/sub/imul in the selector's two-address shape
// (dst = dst op src). A differing first source is copied into dst first.
// Slot destinations load into rax, operate, and store back.
fn (mut e Emitter) emit_binop(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if !ins.has_dst || ins.srcs.len != 2 {
		return error('vir: ${ins.op} needs a destination and two sources')
	}
	if !same_operand(ins.srcs[0], ins.dst) {
		e.emit_mov(mach.MachineInstr{
			op:      .mov
			dst:     ins.dst
			has_dst: true
			srcs:    [ins.srcs[0]]
		}, mut ctx)!
	}
	if ins.dst.kind == .reg {
		dst_hw := e.hw_reg(ins.dst.reg)!
		e.emit_alu(ins.op, dst_hw, ins.srcs[1], mut ctx)!
		return
	}
	if ins.dst.kind == .slot {
		base_hw, disp := e.mem_addr(ins.dst, ctx)!
		e.emit_reg_mem(0x8B, 0, base_hw, disp)
		e.emit_alu(ins.op, 0, ins.srcs[1], mut ctx)!
		e.emit_reg_mem(0x89, 0, base_hw, disp)
		return
	}
	return error('vir: ${ins.op} destination must be a register or slot')
}

// emit_neg encodes neg over a register or slot destination.
fn (mut e Emitter) emit_neg(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if !ins.has_dst || ins.srcs.len != 1 {
		return error('vir: neg needs a destination and one source')
	}
	if !same_operand(ins.srcs[0], ins.dst) {
		e.emit_mov(mach.MachineInstr{
			op:      .mov
			dst:     ins.dst
			has_dst: true
			srcs:    [ins.srcs[0]]
		}, mut ctx)!
	}
	if ins.dst.kind == .reg {
		e.emit_neg_reg(e.hw_reg(ins.dst.reg)!)
		return
	}
	if ins.dst.kind == .slot {
		base_hw, disp := e.mem_addr(ins.dst, ctx)!
		e.emit_reg_mem(0x8B, 0, base_hw, disp)
		e.emit_neg_reg(0)
		e.emit_reg_mem(0x89, 0, base_hw, disp)
		return
	}
	return error('vir: neg destination must be a register or slot')
}

// emit_cmp encodes cmp a, b. A slot or memory left operand is loaded into
// rax first; the right operand then takes any register/imm/memory form.
fn (mut e Emitter) emit_cmp(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if ins.srcs.len != 2 {
		return error('vir: cmp needs two sources')
	}
	left_hw := e.load_cmp_lhs(ins.srcs[0], mut ctx)!
	e.emit_alu(.cmp, left_hw, ins.srcs[1], mut ctx)!
}

// load_cmp_lhs returns the hardware register holding the left comparison
// operand, loading slots and memory into rax (never allocated) when needed.
fn (mut e Emitter) load_cmp_lhs(o mach.Operand, mut ctx FuncCtx) !int {
	if o.kind == .reg {
		return e.hw_reg(o.reg)!
	}
	if o.kind == .slot || o.kind == .mem {
		base_hw, disp := e.mem_addr(o, ctx)!
		e.emit_reg_mem(0x8B, 0, base_hw, disp)
		return 0
	}
	return error('vir: unsupported left operand for cmp')
}

// emit_alu encodes `dst_hw op= src` for add/sub/imul/cmp against a register,
// immediate, slot or memory source.
fn (mut e Emitter) emit_alu(mop mach.MachineOp, dst_hw int, src mach.Operand, mut ctx FuncCtx) ! {
	match src.kind {
		.reg {
			src_hw := e.hw_reg(src.reg)!
			match mop {
				.add {
					e.emit_reg_reg(0x01, dst_hw, src_hw)
				}
				.sub {
					e.emit_reg_reg(0x29, dst_hw, src_hw)
				}
				.cmp {
					e.emit_reg_reg(0x39, dst_hw, src_hw)
				}
				.imul {
					e.emit_imul_reg_reg(dst_hw, src_hw)
				}
				else {
					return error('vir: ${mop} is not an ALU op')
				}
			}
		}
		.imm {
			match mop {
				.add {
					e.emit_alu_imm(0, dst_hw, src.imm)
				}
				.sub {
					e.emit_alu_imm(5, dst_hw, src.imm)
				}
				.cmp {
					e.emit_alu_imm(7, dst_hw, src.imm)
				}
				.imul {
					e.emit_imul_imm(dst_hw, src.imm)
				}
				else {
					return error('vir: ${mop} is not an ALU op')
				}
			}
		}
		.slot, .mem {
			base_hw, disp := e.mem_addr(src, ctx)!
			match mop {
				.add {
					e.emit_reg_mem(0x03, dst_hw, base_hw, disp)
				}
				.sub {
					e.emit_reg_mem(0x2B, dst_hw, base_hw, disp)
				}
				.cmp {
					e.emit_reg_mem(0x3B, dst_hw, base_hw, disp)
				}
				.imul {
					e.emit_imul_reg_mem(dst_hw, base_hw, disp)
				}
				else {
					return error('vir: ${mop} is not an ALU op')
				}
			}
		}
		.symbol {
			return error('vir: ${mop} with a symbol operand is unsupported')
		}
	}
}

// emit_setcc encodes setcc + movzx into a register destination, or the
// upstream al/rax shape followed by a spill for slot destinations.
fn (mut e Emitter) emit_setcc(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if !ins.has_dst {
		return error('vir: setcc needs a destination')
	}
	cc := cc_byte(ins.cond)
	if ins.dst.kind == .reg {
		hw := e.hw_reg(ins.dst.reg)!
		// A REX prefix is required to name spl/bpl/sil/dil and r8b-r15b
		// instead of ah/ch/dh/bh (same rule as the byte-store template).
		if hw >= 4 {
			mut rex := u8(0x40)
			if hw >= 8 {
				rex |= 1
			}
			e.emit(rex)
		}
		e.emit(0x0F)
		e.emit(cc)
		e.emit(u8(0xC0 | (hw & 7)))
		// movzx dst64, dst8
		mut rex_w := u8(0x48)
		if hw >= 8 {
			rex_w |= 5 // REX.R | REX.B
		}
		e.emit(rex_w)
		e.emit(0x0F)
		e.emit(0xB6)
		e.emit(u8(0xC0 | ((hw & 7) << 3) | (hw & 7)))
		return
	}
	if ins.dst.kind == .slot {
		e.emit(0x0F) // setcc al
		e.emit(cc)
		e.emit(0xC0)
		e.emit(0x48) // movzx rax, al
		e.emit(0x0F)
		e.emit(0xB6)
		e.emit(0xC0)
		base_hw, disp := e.mem_addr(ins.dst, ctx)!
		e.emit_reg_mem(0x89, 0, base_hw, disp)
		return
	}
	return error('vir: setcc destination must be a register or slot')
}

// emit_branch encodes jmp/jcc as rel32 and records the patch site; the
// displacement is filled in after the whole function is laid out.
fn (mut e Emitter) emit_branch(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if ins.op == .jmp {
		e.emit(0xE9) // jmp rel32
	} else {
		e.emit(0x0F) // jcc rel32
		e.emit(cc_byte(ins.cond) - 0x10)
	}
	ctx.patches << BranchPatch{
		site:   e.text.len
		target: ins.target
	}
	e.emit_u32(0)
}

// emit_call encodes call rel32. Like upstream, every callee (internal or
// external) becomes an undefined symbol plus an R_X86_64_PLT32 relocation
// with addend -4; the linker resolves internal names against this object's
// own definition. Arguments must already sit in the ABI registers.
fn (mut e Emitter) emit_call(ins mach.MachineInstr) ! {
	if ins.symbol == '' {
		return error('vir: call without a callee symbol')
	}
	sym := e.sym_undefined(ins.symbol, true)
	e.emit(0xE8) // call rel32
	e.relocs << EmitReloc{
		offset: u32(e.text.len)
		sym:    sym
		typ:    r_x86_64_plt32
		addend: -4
	}
	e.emit_u32(0)
}

// emit_load encodes load dst, [base+disp] into a register or slot.
fn (mut e Emitter) emit_load(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if !ins.has_dst || ins.srcs.len != 1 || ins.srcs[0].kind != .mem {
		return error('vir: load needs a destination and a memory source')
	}
	base_hw, disp := e.mem_addr(ins.srcs[0], ctx)!
	if ins.dst.kind == .reg {
		e.emit_reg_mem(0x8B, e.hw_reg(ins.dst.reg)!, base_hw, disp)
		return
	}
	if ins.dst.kind == .slot {
		db, dd := e.mem_addr(ins.dst, ctx)!
		e.emit_reg_mem(0x8B, 0, base_hw, disp)
		e.emit_reg_mem(0x89, 0, db, dd)
		return
	}
	return error('vir: load destination must be a register or slot')
}

// emit_store encodes store [base+disp], value for register, immediate,
// slot or symbol values (the latter three go through rax).
fn (mut e Emitter) emit_store(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if ins.srcs.len != 2 || ins.srcs[0].kind != .mem {
		return error('vir: store needs a memory destination and a value')
	}
	base_hw, disp := e.mem_addr(ins.srcs[0], ctx)!
	v := ins.srcs[1]
	match v.kind {
		.reg {
			e.emit_reg_mem(0x89, e.hw_reg(v.reg)!, base_hw, disp)
		}
		.imm {
			e.emit_movi_value(0, v.imm)
			e.emit_reg_mem(0x89, 0, base_hw, disp)
		}
		.slot, .mem {
			vb, vd := e.mem_addr(v, ctx)!
			e.emit_reg_mem(0x8B, 0, vb, vd)
			e.emit_reg_mem(0x89, 0, base_hw, disp)
		}
		.symbol {
			e.emit_lea_rip(0, v.symbol)
			e.emit_reg_mem(0x89, 0, base_hw, disp)
		}
	}
}

// === Encoding primitives (shapes copied from vlib/v/gen/amd64/asm.v) ===

// emit appends one byte.
fn (mut e Emitter) emit(b u8) {
	e.text << b
}

// emit_u32 appends a little-endian 32-bit word.
fn (mut e Emitter) emit_u32(v u32) {
	e.emit(u8(v))
	e.emit(u8(v >> 8))
	e.emit(u8(v >> 16))
	e.emit(u8(v >> 24))
}

// emit_u64 appends a little-endian 64-bit word.
fn (mut e Emitter) emit_u64(v u64) {
	e.emit_u32(u32(v))
	e.emit_u32(u32(v >> 32))
}

// patch_u32 overwrites a little-endian 32-bit word at an earlier offset.
fn (mut e Emitter) patch_u32(off int, v u32) {
	e.text[off] = u8(v)
	e.text[off + 1] = u8(v >> 8)
	e.text[off + 2] = u8(v >> 16)
	e.text[off + 3] = u8(v >> 24)
}

// emit_reg_reg encodes `op dst, src` (mov/add/sub/cmp shape): REX.W with
// REX.R for a high source and REX.B for a high destination, source in the
// ModRM reg field, destination in r/m.
fn (mut e Emitter) emit_reg_reg(opcode u8, dst_hw int, src_hw int) {
	mut rex := u8(0x48)
	if src_hw >= 8 {
		rex |= 4
	}
	if dst_hw >= 8 {
		rex |= 1
	}
	e.emit(rex)
	e.emit(opcode)
	e.emit(u8(0xC0 | ((src_hw & 7) << 3) | (dst_hw & 7)))
}

// emit_reg_mem encodes a register/memory form: `op reg, [base+disp]` for
// loads (0x8B) and ALU (0x03/0x2B/0x3B), or `mov [base+disp], reg` for
// stores (0x89). The register sits in the ModRM reg field either way.
fn (mut e Emitter) emit_reg_mem(opcode u8, reg_hw int, base_hw int, disp int) {
	mut rex := u8(0x48)
	if reg_hw >= 8 {
		rex |= 4
	}
	if base_hw >= 8 {
		rex |= 1
	}
	e.emit(rex)
	e.emit(opcode)
	e.emit_modrm_mem(reg_hw, base_hw, disp)
}

// emit_modrm_mem emits the ModRM byte plus SIB and displacement for
// [base+disp]: disp0 skips the displacement except on rbp/r13, rsp/r12
// always take a SIB, and small displacements use the disp8 form.
fn (mut e Emitter) emit_modrm_mem(reg_field int, base_hw int, disp int) {
	rm := base_hw & 7
	needs_sib := rm == 4 // rsp/r12
	if disp == 0 && rm != 5 {
		e.emit(u8(((reg_field & 7) << 3) | rm))
		if needs_sib {
			e.emit(0x24)
		}
	} else if disp >= -128 && disp <= 127 {
		e.emit(u8(0x40 | ((reg_field & 7) << 3) | rm))
		if needs_sib {
			e.emit(0x24)
		}
		e.emit(u8(disp))
	} else {
		e.emit(u8(0x80 | ((reg_field & 7) << 3) | rm))
		if needs_sib {
			e.emit(0x24)
		}
		e.emit_u32(u32(disp))
	}
}

// emit_movi_value materializes an immediate into a register: mov imm32
// zero-extends, so non-negative values up to 32 bits use the short form;
// everything else (negatives included) uses movabs imm64.
fn (mut e Emitter) emit_movi_value(dst_hw int, imm i64) {
	if imm >= 0 && imm <= i64(0xFFFFFFFF) {
		e.emit_mov_imm32(dst_hw, u32(imm))
	} else {
		e.emit_mov_imm64(dst_hw, u64(imm))
	}
}

// emit_mov_imm32 encodes mov reg, imm32 (zero-extends to 64 bits).
fn (mut e Emitter) emit_mov_imm32(dst_hw int, imm u32) {
	if dst_hw >= 8 {
		e.emit(0x41) // REX.B
	}
	e.emit(u8(0xB8 | (dst_hw & 7)))
	e.emit_u32(imm)
}

// emit_mov_imm64 encodes movabs reg, imm64.
fn (mut e Emitter) emit_mov_imm64(dst_hw int, imm u64) {
	mut rex := u8(0x48)
	if dst_hw >= 8 {
		rex |= 1
	}
	e.emit(rex)
	e.emit(u8(0xB8 | (dst_hw & 7)))
	e.emit_u64(imm)
}

// emit_alu_imm encodes add/sub/cmp reg, imm via the 0x83 /digit imm8 form
// when the immediate fits in a signed byte, else 0x81 /digit imm32.
fn (mut e Emitter) emit_alu_imm(digit int, dst_hw int, imm i64) {
	mut rex := u8(0x48)
	if dst_hw >= 8 {
		rex |= 1
	}
	e.emit(rex)
	modrm := u8(0xC0 | (digit << 3) | (dst_hw & 7))
	if imm >= -128 && imm <= 127 {
		e.emit(0x83)
		e.emit(modrm)
		e.emit(u8(imm))
	} else {
		e.emit(0x81)
		e.emit(modrm)
		e.emit_u32(u32(imm))
	}
}

// emit_imul_reg_reg encodes imul dst, src: destination in the ModRM reg
// field, source in r/m (the template's 0x0F 0xAF shape).
fn (mut e Emitter) emit_imul_reg_reg(dst_hw int, src_hw int) {
	mut rex := u8(0x48)
	if dst_hw >= 8 {
		rex |= 4 // REX.R: dst
	}
	if src_hw >= 8 {
		rex |= 1 // REX.B: src
	}
	e.emit(rex)
	e.emit(0x0F)
	e.emit(0xAF)
	e.emit(u8(0xC0 | ((dst_hw & 7) << 3) | (src_hw & 7)))
}

// emit_imul_reg_mem encodes imul dst, [base+disp].
fn (mut e Emitter) emit_imul_reg_mem(dst_hw int, base_hw int, disp int) {
	mut rex := u8(0x48)
	if dst_hw >= 8 {
		rex |= 4
	}
	if base_hw >= 8 {
		rex |= 1
	}
	e.emit(rex)
	e.emit(0x0F)
	e.emit(0xAF)
	e.emit_modrm_mem(dst_hw, base_hw, disp)
}

// emit_imul_imm encodes the three-operand form imul dst, dst, imm using
// 0x6B imm8 when it fits, else 0x69 imm32.
fn (mut e Emitter) emit_imul_imm(dst_hw int, imm i64) {
	mut rex := u8(0x48)
	if dst_hw >= 8 {
		rex |= 1
	}
	e.emit(rex)
	modrm := u8(0xC0 | ((dst_hw & 7) << 3) | (dst_hw & 7))
	if imm >= -128 && imm <= 127 {
		e.emit(0x6B)
		e.emit(modrm)
		e.emit(u8(imm))
	} else {
		e.emit(0x69)
		e.emit(modrm)
		e.emit_u32(u32(imm))
	}
}

// emit_neg_reg encodes neg reg (0xF7 /3, the template's idiv/div group).
fn (mut e Emitter) emit_neg_reg(dst_hw int) {
	mut rex := u8(0x48)
	if dst_hw >= 8 {
		rex |= 1
	}
	e.emit(rex)
	e.emit(0xF7)
	e.emit(u8(0xD8 | (dst_hw & 7)))
}

// emit_lea_rip encodes lea reg, [rip+disp32] with an R_X86_64_PC32
// relocation (addend -4) against the named symbol.
fn (mut e Emitter) emit_lea_rip(dst_hw int, name string) {
	sym := e.sym_undefined(name, false)
	mut rex := u8(0x48)
	if dst_hw >= 8 {
		rex |= 4
	}
	e.emit(rex)
	e.emit(0x8D)
	e.emit(u8(0x05 | ((dst_hw & 7) << 3)))
	e.relocs << EmitReloc{
		offset: u32(e.text.len)
		sym:    sym
		typ:    r_x86_64_pc32
		addend: -4
	}
	e.emit_u32(0)
}

// === Operand and symbol resolution ===

// hw_reg maps a physical register to its amd64 hardware encoding index
// (rax=0 .. r15=15). Virtual registers must not survive to emission.
fn (e &Emitter) hw_reg(r mach.Reg) !int {
	if r.virt == fp_vreg {
		return error('vir: fp placeholder is only valid as a memory base')
	}
	if !r.is_phys() {
		return error('vir: vreg %v${r.virt} survived allocation')
	}
	if r.phys.arch != .amd64 || r.phys.is_float {
		return error('vir: amd64 emitter needs integer registers, got ${r.phys.name()}')
	}
	if r.phys.index < 0 || r.phys.index > 15 {
		return error('vir: bad physical register index ${r.phys.index}')
	}
	return r.phys.index
}

// mem_addr resolves a slot or memory operand to (base hw index, disp).
// Slots bind below the frame pointer: slot n -> [rbp-(n+1)*8]. Memory with
// the fp placeholder base follows the sign convention: non-negative
// displacements address the incoming stack argument area above the saved
// rbp and return address ([rbp+16+disp]); negative displacements address
// the frame itself ([rbp+disp], used for spilled pointer bases).
fn (e &Emitter) mem_addr(o mach.Operand, ctx FuncCtx) !(int, int) {
	if o.kind == .slot {
		if o.slot < 0 || o.slot >= ctx.stack_slots {
			return error('vir: slot ${o.slot} outside frame of ${ctx.stack_slots} slots')
		}
		return 5, -(o.slot + 1) * 8
	}
	if o.kind != .mem {
		return error('vir: expected a slot or memory operand')
	}
	if o.base.virt == fp_vreg {
		if o.disp < 0 {
			return 5, o.disp
		}
		return 5, 16 + o.disp
	}
	base_hw := e.hw_reg(o.base)!
	return base_hw, o.disp
}

// cc_byte maps a condition to its setcc opcode byte; jcc uses byte - 0x10.
fn cc_byte(c mach.Cond) u8 {
	return match c {
		.eq { 0x94 }
		.ne { 0x95 }
		.lt { 0x9C }
		.le { 0x9E }
		.gt { 0x9F }
		.ge { 0x9D }
		.ult { 0x92 }
		.ule { 0x96 }
		.ugt { 0x97 }
		.uge { 0x93 }
	}
}

// same_operand reports whether two operands name the same location.
fn same_operand(a mach.Operand, b mach.Operand) bool {
	if a.kind != b.kind {
		return false
	}
	return match a.kind {
		.reg {
			same_reg(a.reg, b.reg)
		}
		.imm {
			a.imm == b.imm
		}
		.mem {
			same_reg(a.base, b.base) && a.disp == b.disp
		}
		.symbol {
			a.symbol == b.symbol
		}
		.slot {
			a.slot == b.slot
		}
	}
}

// same_reg reports whether two registers name the same location.
fn same_reg(a mach.Reg, b mach.Reg) bool {
	return a.virt == b.virt && a.phys.arch == b.phys.arch && a.phys.index == b.phys.index
		&& a.phys.is_float == b.phys.is_float
}

// sym_define adds or upgrades a defined function symbol, mirroring the
// upstream ELF writer: a name first seen as a call target keeps its index
// and becomes defined here.
fn (mut e Emitter) sym_define(name string, offset u32) int {
	if idx := e.sym_idx[name] {
		e.syms[idx].is_func = true
		e.syms[idx].is_undefined = false
		e.syms[idx].offset = offset
		return idx
	}
	idx := e.syms.len
	e.syms << EmitSym{
		name:    name
		is_func: true
		offset:  offset
	}
	e.sym_idx[name] = idx
	return idx
}

// sym_undefined returns the symbol index for a reference, creating an
// undefined entry on first use. Existing definitions are reused as-is.
fn (mut e Emitter) sym_undefined(name string, is_func bool) int {
	if idx := e.sym_idx[name] {
		return idx
	}
	idx := e.syms.len
	e.syms << EmitSym{
		name:         name
		is_func:      is_func
		is_undefined: true
	}
	e.sym_idx[name] = idx
	return idx
}
