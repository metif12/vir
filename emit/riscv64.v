module emit

// RV64I emitter for vir (post-v1 riscv64 slice). Integer subset only, mirroring
// the amd64 v1 scope: the MachineOp set lowers one-to-one, comparisons fuse
// cmp+setcc / cmp+jcc pairs (RISC-V has no flags), and calls use jal plus an
// R_RISCV_JAL relocation. Stack call arguments are rejected upstream by ISel,
// so outgoing calls need no stack area. a0/a1 double as fusion temporaries
// and are excluded from the register pool for exactly that reason.

import mach
import target

// r_riscv_jal is the ELF RISC-V relocation type for a jal instruction.
pub const r_riscv_jal = 17

const rv_sp = 2
const rv_fp = 8
const rv_a0 = 10
const rv_a1 = 11

// rv_fp_vreg mirrors mach's private frame-pointer placeholder (-100). It is
// only valid as a memory base.
const rv_fp_vreg = -100

// RiscvEmitter accumulates text, symbols, relocations and line rows for one
// module. Shared output types (EmitSym, EmitReloc, LineRow, BranchPatch,
// FuncCtx) live in amd64.v; only the encoding below is arch-specific.
struct RiscvEmitter {
mut:
	text      []u8
	syms      []EmitSym
	sym_idx   map[string]int
	relocs    []EmitReloc
	line_rows []LineRow
	addr_rows []AddrRow
}

// emit_riscv64 encodes a register-allocated machine module into RV64I text
// plus symbols and relocations. The module must already satisfy
// mach.assert_no_vregs: only physical registers and stack slots may remain.
pub fn emit_riscv64(m &mach.MachineModule, t target.Triple) !EmitOutput {
	if t.arch != .riscv64 {
		return error('vir: riscv64 emitter cannot target ${t.arch}')
	}
	mach.assert_no_vregs(m)!
	mut e := RiscvEmitter{
		sym_idx: map[string]int{}
	}
	for f in m.funcs {
		e.emit_func(f)!
	}
	return EmitOutput{
		text:      e.text
		syms:      e.syms
		relocs:    e.relocs
		line_rows: e.line_rows
		addr_rows: e.addr_rows
	}
}

// emit_func lays out one function: prologue, blocks in order, jal
// back-patching, then the symbol size. Entry moves are already part of
// block 0 and are emitted as-is.
fn (mut e RiscvEmitter) emit_func(f mach.MachineFunc) ! {
	if f.blocks.len == 0 {
		return error('vir: function ${f.name} has no blocks')
	}
	func_off := e.text.len
	sym := e.sym_define(f.name, u32(func_off))
	// Frame: spill slots plus saved ra/fp, 16-byte aligned. fp is set to the
	// entry sp, so incoming stack slots address [fp+n*8] while spills live
	// below the saved pair at [fp-(n+3)*8].
	frame := (f.stack_slots * 8 + 16 + 15) & ~15
	e.emit_addi(rv_sp, rv_sp, -i32(frame))!
	e.emit_sd(rv_fp, rv_sp, i32(frame - 16))!
	e.emit_sd(1, rv_sp, i32(frame - 8))! // ra
	e.emit_addi(rv_fp, rv_sp, i32(frame))!
	mut ctx := FuncCtx{
		stack_slots: f.stack_slots
		frame:       frame
		block_offs:  map[int]int{}
	}
	// Entry locations for DWARF variable DIEs, resolved against the frame.
	e.syms[sym].params = e.debug_params(f, ctx)!
	for b in f.blocks {
		ctx.block_offs[b.id] = e.text.len
		// Explicit index: a fused cmp consumes its setcc/jcc consumer, so
		// the loop must skip the instruction after a cmp.
		mut n := 0
		for n < b.instrs.len {
			ins := b.instrs[n]
			if ins.line > 0 {
				if e.line_rows.len == 0
					|| e.line_rows[e.line_rows.len - 1].line != ins.line {
					e.line_rows << LineRow{ offset: u32(e.text.len), line: ins.line }
				}
			}
			// Comparisons fuse with their consumer: a cmp is always followed
			// by the setcc/jcc that reads it.
			if ins.op == .cmp {
				if n + 1 >= b.instrs.len {
					return error('vir: riscv64 cmp without a consumer')
				}
				next := b.instrs[n + 1]
				start := e.text.len
				if next.op == .setcc {
					e.emit_fused_setcc(ins, next, mut ctx)!
				} else if next.op == .jcc {
					e.emit_fused_jcc(ins, next, mut ctx)!
				} else {
					return error('vir: riscv64 cmp must feed setcc or jcc, got ${next.op}')
				}
				// One row spans the fusion; the consumer carries the home.
				e.addr_mark_fused(start, next, ctx)!
				n += 2
				continue
			}
			if ins.op == .setcc {
				return error('vir: riscv64 setcc without a preceding cmp')
			}
			start := e.text.len
			e.emit_instr(ins, mut ctx)!
			e.addr_mark(start, ins, ctx)!
			n++
		}
	}
	// Second pass: every block offset is known, so patch all jal fields.
	for p in ctx.patches {
		target_off := ctx.block_offs[p.target] or {
			return error('vir: branch to unknown block @b${p.target} in ${f.name}')
		}
		off := i64(target_off) - i64(p.site)
		e.patch_jal(p.site, i32(off))!
	}
	// Guard against fall-through into the next function when the last block
	// does not end in ret or an unconditional jump.
	last := f.blocks[f.blocks.len - 1].instrs
	if last.len == 0 || (last[last.len - 1].op != .ret && last[last.len - 1].op != .jmp) {
		e.emit_epilogue(frame)!
	}
	e.syms[sym].size = u32(e.text.len - func_off)
}

// emit_instr encodes one non-comparison machine instruction.
fn (mut e RiscvEmitter) emit_instr(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	match ins.op {
		.mov { e.emit_mov(ins, mut ctx)! }
		.movi { e.emit_movi(ins, mut ctx)! }
		.add, .sub, .imul { e.emit_binop(ins, mut ctx)! }
		.neg { e.emit_neg(ins, mut ctx)! }
		.jmp { e.emit_jmp(ins, mut ctx)! }
		.jcc { return error('vir: riscv64 jcc must follow a cmp (fusion bypassed)') }
		.call { e.emit_call(ins)! }
		.ret { e.emit_ret(ins, mut ctx)! }
		.load { e.emit_load(ins, mut ctx)! }
		.store { e.emit_store(ins, mut ctx)! }
		else { return error('vir: riscv64 emitter rejects ${ins.op}') }
	}
}

// debug_params maps each function parameter to its DWARF entry location:
// a register number, or a frame-base-relative offset. RISC-V hardware
// numbers already match the DWARF numbering (x0-x31).
fn (mut e RiscvEmitter) debug_params(f mach.MachineFunc, ctx FuncCtx) ![]EmitParam {
	mut out := []EmitParam{}
	for i, p in f.params {
		name := if i < f.param_names.len { f.param_names[i] } else { 'arg${i}' }
		if p.kind == .reg {
			if !p.reg.is_phys() {
				return error('vir: riscv64 parameter in virtual register')
			}
			out << EmitParam{ name: name, is_reg: true, reg: p.reg.phys.index }
		} else if p.kind == .mem || p.kind == .slot {
			base, disp := e.resolve_mem(p, ctx)!
			out << EmitParam{ name: name, breg: base, offset: disp }
		} else {
			return error('vir: cannot describe riscv64 parameter location')
		}
	}
	return out
}

// Slots bind below the saved ra/fp pair: slot n lives at [fp-(n+3)*8],
// leaving [fp-8] and [fp-16] for the callee-saved pair. Memory with the
// fp placeholder base addresses the frame itself for negative
// displacements and the incoming stack argument area for non-negative ones.
fn (mut e RiscvEmitter) resolve_mem(o mach.Operand, ctx FuncCtx) !(int, i32) {
	if o.kind == .slot {
		if o.slot < 0 || o.slot >= ctx.stack_slots {
			return error('vir: slot ${o.slot} outside frame of ${ctx.stack_slots} slots')
		}
		return rv_fp, -i32(o.slot + 3) * 8
	}
	if o.kind != .mem {
		return error('vir: expected a slot or memory operand')
	}
	if o.base.virt == rv_fp_vreg {
		return rv_fp, i32(o.disp)
	}
	base := e.hw_reg(o.base)!
	return base, i32(o.disp)
}

// hw_reg maps an allocated register to its RISC-V hardware number. The
// frame-pointer placeholder is only valid as a memory base.
fn (mut e RiscvEmitter) hw_reg(r mach.Reg) !int {
	if r.virt == rv_fp_vreg {
		return error('vir: fp placeholder is only valid as a memory base')
	}
	if !r.is_phys() {
		return error('vir: vreg %v${r.virt} survived allocation')
	}
	if r.phys.arch != .riscv64 || r.phys.is_float {
		return error('vir: riscv64 emitter needs integer registers, got ${r.phys.name()}')
	}
	if r.phys.index < 0 || r.phys.index > 31 {
		return error('vir: bad physical register index ${r.phys.index}')
	}
	return r.phys.index
}

// check_imm12 rejects displacements the ld/sd/addi formats cannot encode.
fn check_imm12(v i32) ! {
	if v < -2048 || v > 2047 {
		return error('vir: riscv64 displacement ${v} exceeds 12 bits')
	}
}

// Raw RV64I encoders. Each returns the 32-bit instruction word; callers
// write it little-endian with emit_u32.
fn rv_r(funct7 u32, rs2 int, rs1 int, funct3 u32, rd int) u32 {
	return (funct7 << 25) | (u32(rs2) << 20) | (u32(rs1) << 15) | (funct3 << 12) | (u32(rd) << 7) | 0x33
}

fn rv_i(imm i32, rs1 int, funct3 u32, rd int, opcode u32) !u32 {
	check_imm12(imm)!
	return ((u32(imm) & 0xfff) << 20) | (u32(rs1) << 15) | (funct3 << 12) | (u32(rd) << 7) | opcode
}

fn rv_s(imm i32, rs2 int, rs1 int, funct3 u32) !u32 {
	check_imm12(imm)!
	u := u32(imm) & 0xfff
	return ((u >> 5) << 25) | (u32(rs2) << 20) | (u32(rs1) << 15) | (funct3 << 12) | ((u & 0x1f) << 7) | 0x23
}

fn rv_b(funct3 u32, rs1 int, rs2 int, off i32) !u32 {
	if off % 2 != 0 || off < -4096 || off > 4094 {
		return error('vir: riscv64 branch offset ${off} out of range')
	}
	u := u32(off) & 0x1fff
	return (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3f) << 25) | (u32(rs2) << 20) | (u32(rs1) << 15) | (funct3 << 12) | (((u >> 1) & 0xf) << 8) | (((u >> 11) & 1) << 7) | 0x63
}

fn rv_jal(rd int, off i32) !u32 {
	if off % 2 != 0 || off < -(1 << 20) || off > (1 << 20) - 2 {
		return error('vir: riscv64 jump offset ${off} out of range')
	}
	u := u32(off) & 0x1fffff
	return (((u >> 20) & 1) << 31) | (((u >> 1) & 0x3ff) << 21) | (((u >> 11) & 1) << 20) | (((u >> 12) & 0xff) << 12) | (u32(rd) << 7) | 0x6f
}

fn rv_lui(rd int, hi u32) u32 {
	return ((hi & 0xfffff) << 12) | (u32(rd) << 7) | 0x37
}

fn (mut e RiscvEmitter) emit_u32(v u32) {
	e.text << u8(v)
	e.text << u8(v >> 8)
	e.text << u8(v >> 16)
	e.text << u8(v >> 24)
}

fn (mut e RiscvEmitter) emit_addi(rd int, rs1 int, imm i32) ! {
	e.emit_u32(rv_i(imm, rs1, 0, rd, 0x13)!)
}

fn (mut e RiscvEmitter) emit_ld(rd int, base int, disp i32) ! {
	e.emit_u32(rv_i(disp, base, 3, rd, 0x03)!)
}

fn (mut e RiscvEmitter) emit_sd(rs int, base int, disp i32) ! {
	e.emit_u32(rv_s(disp, rs, base, 3)!)
}

// emit_epilogue restores ra/fp and deallocates the frame; the caller appends
// the return jump.
fn (mut e RiscvEmitter) emit_epilogue(frame int) ! {
	e.emit_ld(1, rv_sp, i32(frame - 8))! // ra
	e.emit_ld(rv_fp, rv_sp, i32(frame - 16))!
	e.emit_addi(rv_sp, rv_sp, i32(frame))!
}

// emit_mov lowers a register-to-register move; other shapes go through
// temporaries (a0/a1 are never allocated, so they are safe scratch).
fn (mut e RiscvEmitter) emit_mov(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if ins.dst.kind == .reg && ins.srcs.len == 1 && ins.srcs[0].kind == .reg {
		e.emit_addi(e.hw_reg(ins.dst.reg)!, e.hw_reg(ins.srcs[0].reg)!, 0)!
		return
	}
	// General shape: materialize the source in a0, then store or move it.
	src := ins.srcs[0]
	match src.kind {
		.reg { e.emit_addi(rv_a0, e.hw_reg(src.reg)!, 0)! }
		.imm {
			e.emit_li(rv_a0, src.imm)!
		}
		.mem, .slot {
			base, disp := e.resolve_mem(src, ctx)!
			e.emit_ld(rv_a0, base, disp)!
		}
		.symbol {
			return error('vir: riscv64 mov with a symbol operand is unsupported')
		}
	}
	if ins.dst.kind == .reg {
		e.emit_addi(e.hw_reg(ins.dst.reg)!, rv_a0, 0)!
	} else if ins.dst.kind == .slot || ins.dst.kind == .mem {
		base, disp := e.resolve_mem(ins.dst, ctx)!
		e.emit_sd(rv_a0, base, disp)!
	} else {
		return error('vir: riscv64 mov destination must be a register or slot')
	}
}

// emit_li materializes any 32-bit signed value: a single addi when it fits
// in 12 bits, else lui plus addi with the standard rounding.
fn (mut e RiscvEmitter) emit_li(dst int, v i64) ! {
	if v >= -2048 && v <= 2047 {
		e.emit_addi(dst, 0, i32(v))!
		return
	}
	if v < -2147483648 || v > 4294967295 {
		return error('vir: riscv64 immediate ${v} exceeds 32 bits')
	}
	hi := (v + 0x800) >> 12
	lo := v - (hi << 12)
	e.emit_u32(rv_lui(dst, u32(hi & 0xfffff)))
	e.emit_addi(dst, dst, i32(lo))!
}

// emit_movi materializes a 32-bit constant. Larger values are rejected: v1
// fixtures only need the low 32 bits and full 64-bit li synthesis can wait.
fn (mut e RiscvEmitter) emit_movi(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if ins.srcs.len != 1 || ins.srcs[0].kind != .imm {
		return error('vir: riscv64 movi needs one immediate')
	}
	v := ins.srcs[0].imm
	dst := if ins.dst.kind == .reg { e.hw_reg(ins.dst.reg)! } else { rv_a0 }
	e.emit_li(dst, v)!
	if ins.dst.kind == .slot || ins.dst.kind == .mem {
		base, disp := e.resolve_mem(ins.dst, ctx)!
		e.emit_sd(rv_a0, base, disp)!
	} else if ins.dst.kind != .reg {
		return error('vir: riscv64 movi destination must be a register or slot')
	}
}

fn (mut e RiscvEmitter) emit_binop(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if ins.srcs.len != 2 {
		return error('vir: riscv64 binop needs two sources')
	}
	op := match ins.op {
		.add { u32(0) }
		.sub { u32(0x20) }
		.imul { u32(0x01) }
		else { return error('vir: riscv64 binop rejects ${ins.op}') }
	}
	a := e.operand_in_reg(ins.srcs[0], rv_a0, mut ctx)!
	b := e.operand_in_reg(ins.srcs[1], rv_a1, mut ctx)!
	if ins.dst.kind == .reg {
		rd := e.hw_reg(ins.dst.reg)!
		e.emit_u32(rv_r(op, b, a, 0, rd))
	} else if ins.dst.kind == .slot || ins.dst.kind == .mem {
		e.emit_u32(rv_r(op, b, a, 0, rv_a0))
		base, disp := e.resolve_mem(ins.dst, ctx)!
		e.emit_sd(rv_a0, base, disp)!
	} else {
		return error('vir: riscv64 binop destination must be a register or slot')
	}
}

fn (mut e RiscvEmitter) emit_neg(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if ins.srcs.len != 1 {
		return error('vir: riscv64 neg needs one source')
	}
	a := e.operand_in_reg(ins.srcs[0], rv_a0, mut ctx)!
	if ins.dst.kind == .reg {
		e.emit_u32(rv_r(0x20, a, 0, 0, e.hw_reg(ins.dst.reg)!))
	} else if ins.dst.kind == .slot || ins.dst.kind == .mem {
		e.emit_u32(rv_r(0x20, a, 0, 0, rv_a0))
		base, disp := e.resolve_mem(ins.dst, ctx)!
		e.emit_sd(rv_a0, base, disp)!
	} else {
		return error('vir: riscv64 neg destination must be a register or slot')
	}
}

// operand_in_reg materializes any source operand in a register, using `tmp`
// (a0/a1, never allocated) for memory, slot and large-immediate shapes.
fn (mut e RiscvEmitter) operand_in_reg(o mach.Operand, tmp int, mut ctx FuncCtx) !int {
	match o.kind {
		.reg {
			return e.hw_reg(o.reg)!
		}
		.imm {
			e.emit_li(tmp, o.imm)!
			return tmp
		}
		.mem, .slot {
			base, disp := e.resolve_mem(o, ctx)!
			e.emit_ld(tmp, base, disp)!
			return tmp
		}
		else {
			return error('vir: riscv64 cannot materialize ${o.kind} inline')
		}
	}
}

// addr_mark records one machine instruction's address range, SSA origin and
// defining home for DWARF location lists. Instructions without an SSA origin
// (entry moves, materialized constants) are skipped: constants and
// parameters never enter location lists.
fn (mut e RiscvEmitter) addr_mark(start int, ins mach.MachineInstr, ctx FuncCtx) ! {
	e.addr_mark_as(start, ins, ins, ctx)!
}

// addr_mark_fused records one row spanning a fused cmp+consumer pair,
// attributed to the consumer that carries the home (or just the range for
// branches). Both share one SSA origin.
fn (mut e RiscvEmitter) addr_mark_fused(start int, consumer mach.MachineInstr, ctx FuncCtx) ! {
	e.addr_mark_as(start, consumer, consumer, ctx)!
}

fn (mut e RiscvEmitter) addr_mark_as(start int, origin mach.MachineInstr, home mach.MachineInstr, ctx FuncCtx) ! {
	if origin.ssa_id == 0 {
		return
	}
	mut row := AddrRow{
		offset: u32(start)
		size:   u32(e.text.len - start)
		ssa_id: origin.ssa_id
	}
	if home.has_dst {
		if home.dst.kind == .reg {
			if !home.dst.reg.is_phys() {
				return error('vir: riscv64 address row in virtual register')
			}
			row.has_loc = true
			row.is_reg = true
			row.reg = home.dst.reg.phys.index
		} else if home.dst.kind == .mem || home.dst.kind == .slot {
			base, disp := e.resolve_mem(home.dst, ctx)!
			row.has_loc = true
			row.breg = base
			row.off = disp
		}
	}
	e.addr_rows << row
}

// cond_branch maps a condition to its RISC-V branch funct3 and whether the
// operands must be swapped (RISC-V has no greater-than branches).
fn cond_branch(c mach.Cond) !(u32, bool) {
	return match c {
		.eq { // beq
			u32(0), false
		}
		.ne { // bne
			u32(1), false
		}
		.lt { // blt
			u32(4), false
		}
		.ge { // bge
			u32(5), false
		}
		.gt { // blt with swapped operands
			u32(4), true
		}
		.le { // bge with swapped operands
			u32(5), true
		}
		.ult { // bltu
			u32(6), false
		}
		.uge { // bgeu
			u32(7), false
		}
		.ugt { // bltu with swapped operands
			u32(6), true
		}
		.ule { // bgeu with swapped operands
			u32(7), true
		}
	}
}

// emit_fused_setcc lowers cmp(a, b) + setcc(cond) without flags. Operands
// load into a0/a1 (only as needed); a slot destination computes into a free
// temporary first.
fn (mut e RiscvEmitter) emit_fused_setcc(cmp mach.MachineInstr, setcc mach.MachineInstr, mut ctx FuncCtx) ! {
	if cmp.srcs.len != 2 {
		return error('vir: riscv64 cmp needs two sources')
	}
	mut ta := -1
	mut tb := -1
	ta = e.cmp_operand(cmp.srcs[0], rv_a0, mut ctx)!
	if cmp.srcs[1].kind == .imm && cmp.srcs[1].imm == 0 {
		tb = 0
	} else {
		tb = e.cmp_operand(cmp.srcs[1], if ta == rv_a0 { rv_a1 } else { rv_a0 }, mut ctx)!
	}
	rt := if setcc.dst.kind == .reg {
		e.hw_reg(setcc.dst.reg)!
	} else if setcc.dst.kind == .slot || setcc.dst.kind == .mem {
		if ta != rv_a1 && tb != rv_a1 { rv_a1 } else { rv_a0 }
	} else {
		return error('vir: riscv64 setcc destination must be a register or slot')
	}
	match setcc.cond {
		.eq {
			// xor t, a, b; seqz rd, t
			e.emit_u32(rv_r(0, tb, ta, 4, rt))
			e.emit_u32(rv_i(1, rt, 3, rt, 0x13)!)
		}
		.ne {
			// xor t, a, b; snez rd, t
			e.emit_u32(rv_r(0, tb, ta, 4, rt))
			e.emit_u32(rv_r(0, rt, 0, 3, rt))
		}
		.lt, .ult {
			f3 := if setcc.cond == .lt { u32(2) } else { u32(3) }
			e.emit_u32(rv_r(0, tb, ta, f3, rt))
		}
		.gt, .ugt {
			f3 := if setcc.cond == .gt { u32(2) } else { u32(3) }
			e.emit_u32(rv_r(0, ta, tb, f3, rt))
		}
		.ge, .uge {
			f3 := if setcc.cond == .ge { u32(2) } else { u32(3) }
			e.emit_u32(rv_r(0, tb, ta, f3, rt))
			e.emit_u32(rv_i(1, rt, 4, rt, 0x13)!) // xori rd, rd, 1
		}
		.le, .ule {
			f3 := if setcc.cond == .le { u32(2) } else { u32(3) }
			e.emit_u32(rv_r(0, ta, tb, f3, rt))
			e.emit_u32(rv_i(1, rt, 4, rt, 0x13)!) // xori rd, rd, 1
		}
	}
	if setcc.dst.kind == .slot || setcc.dst.kind == .mem {
		base, disp := e.resolve_mem(setcc.dst, ctx)!
		e.emit_sd(rt, base, disp)!
	}
}

// cmp_operand loads a comparison source into `tmp` (a0/a1); register sources
// and the zero immediate pass through without emitting code.
fn (mut e RiscvEmitter) cmp_operand(o mach.Operand, tmp int, mut ctx FuncCtx) !int {
	match o.kind {
		.reg {
			return e.hw_reg(o.reg)!
		}
		.imm {
			if o.imm == 0 {
				return 0
			}
			if o.imm >= -2048 && o.imm <= 2047 {
				e.emit_addi(tmp, 0, i32(o.imm))!
				return tmp
			}
			hi := (o.imm + 0x800) >> 12
			lo := o.imm - (hi << 12)
			e.emit_u32(rv_lui(tmp, u32(hi & 0xfffff)))
			e.emit_addi(tmp, tmp, i32(lo))!
			return tmp
		}
		.mem, .slot {
			base, disp := e.resolve_mem(o, ctx)!
			e.emit_ld(tmp, base, disp)!
			return tmp
		}
		else {
			return error('vir: riscv64 cannot compare ${o.kind}')
		}
	}
}

// emit_fused_jcc lowers cmp(a, b) + jcc(cond) as branch-over-jal: the
// inverted branch skips a patched jal, so only jal needs a relocation entry.
fn (mut e RiscvEmitter) emit_fused_jcc(cmp mach.MachineInstr, jcc mach.MachineInstr, mut ctx FuncCtx) ! {
	if cmp.srcs.len != 2 {
		return error('vir: riscv64 cmp needs two sources')
	}
	f3, swap := cond_branch(jcc.cond)!
	mut ta := e.cmp_operand(cmp.srcs[0], rv_a0, mut ctx)!
	mut tb := if cmp.srcs[1].kind == .imm && cmp.srcs[1].imm == 0 {
		0
	} else {
		e.cmp_operand(cmp.srcs[1], if ta == rv_a0 { rv_a1 } else { rv_a0 }, mut ctx)!
	}
	if swap {
		mut t := ta
		ta = tb
		tb = t
	}
	inv := match f3 {
		u32(0) { u32(1) } // beq -> bne
		u32(1) { u32(0) } // bne -> beq
		u32(4) { u32(5) } // blt -> bge
		u32(5) { u32(4) } // bge -> blt
		u32(6) { u32(7) } // bltu -> bgeu
		else { u32(6) } // bgeu -> bltu
	}
	e.emit_u32(rv_b(inv, ta, tb, 8)!)
	ctx.patches << BranchPatch{
		site:   e.text.len
		target: jcc.target
	}
	e.emit_u32(rv_jal(0, 0)!)
}

// emit_jmp encodes an unconditional jump with a patched jal.
fn (mut e RiscvEmitter) emit_jmp(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	ctx.patches << BranchPatch{
		site:   e.text.len
		target: ins.target
	}
	e.emit_u32(rv_jal(0, 0)!)
}

// emit_call encodes jal ra plus an R_RISCV_JAL relocation; the linker
// resolves internal names against this object's own definition. Arguments
// already sit in a0-a7 (ISel rejects stack call arguments upstream).
fn (mut e RiscvEmitter) emit_call(ins mach.MachineInstr) ! {
	if ins.symbol == '' {
		return error('vir: call without a callee symbol')
	}
	sym := e.sym_undefined(ins.symbol, true)
	e.relocs << EmitReloc{
		offset: u32(e.text.len)
		sym:    sym
		typ:    r_riscv_jal
		addend: 0
	}
	e.emit_u32(rv_jal(1, 0)!)
}

// emit_ret moves the result to a0 when present, then restores the frame.
fn (mut e RiscvEmitter) emit_ret(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if ins.srcs.len == 1 {
		src := ins.srcs[0]
		if src.kind == .reg {
			e.emit_addi(rv_a0, e.hw_reg(src.reg)!, 0)!
		} else {
			a := e.operand_in_reg(src, rv_a0, mut ctx)!
			if a != rv_a0 {
				e.emit_addi(rv_a0, a, 0)!
			}
		}
	} else if ins.srcs.len != 0 {
		return error('vir: riscv64 ret takes zero or one source')
	}
	e.emit_epilogue(ctx.frame)!
	e.emit_u32(rv_i(0, 1, 0, 0, 0x67)!) // jalr x0, 0(ra)
}

fn (mut e RiscvEmitter) emit_load(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if !ins.has_dst || ins.srcs.len != 1 {
		return error('vir: riscv64 load needs a destination and one source')
	}
	base, disp := e.resolve_mem(ins.srcs[0], ctx)!
	if ins.dst.kind == .reg {
		e.emit_ld(e.hw_reg(ins.dst.reg)!, base, disp)!
	} else if ins.dst.kind == .slot || ins.dst.kind == .mem {
		e.emit_ld(rv_a0, base, disp)!
		bd, dd := e.resolve_mem(ins.dst, ctx)!
		e.emit_sd(rv_a0, bd, dd)!
	} else {
		return error('vir: riscv64 load destination must be a register or slot')
	}
}

fn (mut e RiscvEmitter) emit_store(ins mach.MachineInstr, mut ctx FuncCtx) ! {
	if ins.srcs.len != 2 {
		return error('vir: riscv64 store needs a value and a place')
	}
	v := e.operand_in_reg(ins.srcs[0], rv_a0, mut ctx)!
	base, disp := e.resolve_mem(ins.srcs[1], ctx)!
	e.emit_sd(v, base, disp)!
}

// patch_jal fills the jal at `site` with the section-relative `off`.
fn (mut e RiscvEmitter) patch_jal(site int, off i32) ! {
	word := rv_jal(0, off)!
	e.text[site] = u8(word)
	e.text[site + 1] = u8(word >> 8)
	e.text[site + 2] = u8(word >> 16)
	e.text[site + 3] = u8(word >> 24)
}

// sym_define adds or upgrades a defined function symbol, mirroring the
// amd64 emitter: a name first seen as a call target keeps its index and
// becomes defined here.
fn (mut e RiscvEmitter) sym_define(name string, offset u32) int {
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
fn (mut e RiscvEmitter) sym_undefined(name string, is_func bool) int {
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
