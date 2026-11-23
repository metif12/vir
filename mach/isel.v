module mach

import target
import vssa.ssa

// MachineSelector lowers verified, phi-free integer SSA to machine IR
// for amd64, arm64 and riscv64. Run the default optimizer pipeline first;
// floats, aggregates, and memory operations are rejected with clear
// errors. The lowering shape is shared: only registers and the calling
// convention change per target (selected via the triple).
pub struct MachineSelector {
	triple  target.Triple
	cc      target.CallConv
	ret_reg target.PhysReg
mut:
	next_vreg int
	sym       map[int]Reg
	// lines maps an SSA instruction value id to its 1-based source line.
	// Missing keys mean line 0 (unknown); the line emitter skips those.
	lines map[int]int
}

// select_machine lowers a module to machine IR for the triple's arch.
pub fn select_machine(m &ssa.Module, t target.Triple) !MachineModule {
	return select_machine_lines(m, t, map[int]int{})
}

// select_machine_lines lowers like select_machine and stamps each machine
// instruction with its source line from the frontend's line table.
pub fn select_machine_lines(m &ssa.Module, t target.Triple, lines map[int]int) !MachineModule {
	if t.arch != .amd64 && t.arch != .arm64 && t.arch != .riscv64 {
		return error('vir: machine selector supports amd64, arm64 and riscv64, not ${t.arch}')
	}
	cc := target.callconv_for(t)!
	ret_arch := t.arch
	// Integer return register: index 0 (rax/x0) on amd64 and arm64,
	// x10 (a0) on riscv64 where x0 is the hardwired zero.
	ret_idx := if t.arch == .riscv64 { 10 } else { 0 }
	mut sel := MachineSelector{
		triple:  t
		cc:      cc
		ret_reg: target.PhysReg{ arch: ret_arch, index: ret_idx }
		sym:     map[int]Reg{}
		lines:   lines
	}
	mut out := MachineModule{
		triple: '${t.arch}-${t.os}-${t.abi}'
	}
	for f in m.funcs {
		out.funcs << sel.select_func(m, f)!
	}
	return out
}

// select_amd64 lowers a module to amd64 machine IR.
pub fn select_amd64(m &ssa.Module, t target.Triple) !MachineModule {
	if t.arch != .amd64 {
		return error('vir: amd64 selector cannot target ${t.arch}')
	}
	return select_machine(m, t)
}

// vreg_for returns the virtual register for an SSA value, creating it.
fn (mut sel MachineSelector) vreg_for(m &ssa.Module, id ssa.ValueID) !Reg {
	if int(id) <= 0 || int(id) >= m.values.len {
		return error('vir: bad value reference %v${int(id)}')
	}
	if r := sel.sym[int(id)] {
		return r
	}
	r := vreg(sel.next_vreg)
	sel.next_vreg++
	sel.sym[int(id)] = r
	return r
}

// int_width returns the byte width of an integer or pointer type.
fn int_width(m &ssa.Module, typ ssa.TypeID) !int {
	if int(typ) < 0 || int(typ) >= m.type_store.types.len {
		return error('vir: bad type reference')
	}
	t := m.type_store.types[int(typ)]
	if t.kind == .ptr_t {
		return 8
	}
	if t.kind == .int_t && t.width % 8 == 0 {
		w := t.width / 8
		if w == 1 || w == 2 || w == 4 || w == 8 {
			return w
		}
	}
	return error('vir: amd64 selector needs 1/2/4/8-byte ints, got ${t.kind} width ${t.width}')
}

// block_target maps an SSA block id to the machine block id.
fn block_target(blocks map[int]int, id int) !int {
	if t := blocks[id] {
		return t
	}
	return error('vir: branch targets unknown block @b${id}')
}

// cond_for maps an SSA comparison to a branch condition.
fn cond_for(op ssa.OpCode) !Cond {
	return match op {
		.eq { Cond.eq }
		.ne { Cond.ne }
		.lt { Cond.lt }
		.le { Cond.le }
		.gt { Cond.gt }
		.ge { Cond.ge }
		.ult { Cond.ult }
		.ule { Cond.ule }
		.ugt { Cond.ugt }
		.uge { Cond.uge }
		else { return error('vir: not a comparison: ${op}') }
	}
}

// const_int reads an integer constant payload strictly.
fn const_int(m &ssa.Module, id ssa.ValueID) !i64 {
	if int(id) <= 0 || int(id) >= m.values.len {
		return error('vir: bad constant reference')
	}
	v := m.values[int(id)]
	if v.kind != .constant {
		return error('vir: expected constant value')
	}
	return parse_const_int(v.name)!
}

// parse_const_int parses an optionally negative decimal integer strictly.
fn parse_const_int(s string) !i64 {
	if s.len == 0 {
		return error('vir: bad integer constant `${s}`')
	}
	mut neg := false
	mut start := 0
	if s[0] == `-` {
		neg = true
		start = 1
	}
	if start >= s.len {
		return error('vir: bad integer constant `${s}`')
	}
	mut res := i64(0)
	for i in start .. s.len {
		if s[i] < `0` || s[i] > `9` {
			return error('vir: bad integer constant `${s}`')
		}
		res = res * 10 + i64(s[i] - `0`)
	}
	return if neg { -res } else { res }
}

// select_func lowers one function.
fn (mut sel MachineSelector) select_func(m &ssa.Module, f ssa.Function) !MachineFunc {
	mut out := MachineFunc{
		name: f.name
	}
	if f.blocks.len == 0 {
		return error('vir: function ${f.name} has no blocks')
	}
	mut blocks := map[int]int{}
	for i, blk_id in f.blocks {
		blocks[int(blk_id)] = i
		mut nb := MachineBlock{
			id:   i
			name: m.blocks[blk_id].name
		}
		out.blocks << nb
	}
	// Every constant value gets a movi at the top of the entry block, in
	// ID order, so uses (including detached dead code) never dangle.
	for id in 1 .. m.values.len {
		if m.values[id].kind != .constant {
			continue
		}
		r := sel.vreg_for(m, ssa.ValueID(id))!
		v := const_int(m, ssa.ValueID(id))!
		_ = int_width(m, m.values[id].typ)!
		out.blocks[0].instrs << MachineInstr{
			op:      .movi
			dst:     reg_operand(r)
			has_dst: true
			srcs:    [imm_operand(v)]
			line:    sel.lines[id]
		}
	}
	for i, blk_id in f.blocks {
		blk := m.blocks[int(blk_id)]
		for val_id in blk.instrs {
			sel.select_instr(m, val_id, mut out, i, blocks)!
		}
	}
	// Entry moves: function parameters arrive per the calling convention.
	// Register arguments move from their physical register; stack
	// arguments load from the frame area (fp-bound later).
	mut entry_moves := []MachineInstr{}
	mut arg_kinds := []target.Arg{}
	for p in f.params {
		w := int_width(m, m.values[int(p)].typ)!
		arg_kinds << target.Arg{ kind: .int_kind, width: w }
	}
	locs := target.assign_args(sel.cc, arg_kinds)!
	for n, p in f.params {
		r := sel.vreg_for(m, p)!
		loc := locs[n]
		if loc.has_reg {
			entry_moves << MachineInstr{
				op:      .mov
				dst:     reg_operand(r)
				has_dst: true
				srcs:    [reg_operand(preg(loc.reg))]
			}
		} else {
			entry_moves << MachineInstr{
				op:      .load
				dst:     reg_operand(r)
				has_dst: true
				srcs:    [mem_operand(vreg(frame_ptr_vreg), loc.stack_offset)]
			}
		}
	}
	// Prepend entry moves before the materialized constants.
	mut head := entry_moves
	head << out.blocks[0].instrs
	out.blocks[0].instrs = head
	out.params = []Operand{}
	for p in f.params {
		out.params << reg_operand(sel.vreg_for(m, p)!)
	}
	return out
}

// select_instr lowers one SSA instruction. blocks maps SSA block ids to
// machine block ids within this function.
fn (mut sel MachineSelector) select_instr(m &ssa.Module, val_id ssa.ValueID, mut out MachineFunc, blk int, blocks map[int]int) ! {
	if int(val_id) <= 0 || int(val_id) >= m.values.len {
		return error('vir: bad instruction reference')
	}
	val := m.values[int(val_id)]
	if val.kind != .instruction || val.index < 0 || val.index >= m.instrs.len {
		return error('vir: expected instruction value')
	}
	instr := m.instrs[val.index]
	dst := sel.vreg_for(m, val_id)!
	mut emit := []MachineInstr{}
	match instr.op {
		.add, .sub, .mul {
			if instr.operands.len != 2 {
				return error('vir: bad binary operands')
			}
			_ = int_width(m, instr.typ)!
			a := sel.vreg_for(m, instr.operands[0])!
			b := sel.vreg_for(m, instr.operands[1])!
			op := if instr.op == .add {
				MachineOp.add
			} else if instr.op == .sub {
				MachineOp.sub
			} else {
				MachineOp.imul
			}
			emit << MachineInstr{
				op:      .mov
				dst:     reg_operand(dst)
				has_dst: true
				srcs:    [reg_operand(a)]
			}
			emit << MachineInstr{
				op:      op
				dst:     reg_operand(dst)
				has_dst: true
				srcs:    [reg_operand(dst), reg_operand(b)]
			}
		}
		.neg {
			if instr.operands.len != 1 {
				return error('vir: bad neg operands')
			}
			a := sel.vreg_for(m, instr.operands[0])!
			emit << MachineInstr{
				op:      .mov
				dst:     reg_operand(dst)
				has_dst: true
				srcs:    [reg_operand(a)]
			}
			emit << MachineInstr{
				op:      .neg
				dst:     reg_operand(dst)
				has_dst: true
				srcs:    [reg_operand(dst)]
			}
		}
		.lt, .gt, .le, .ge, .eq, .ne, .ult, .ugt, .ule, .uge {
			if instr.operands.len != 2 {
				return error('vir: bad comparison operands')
			}
			a := sel.vreg_for(m, instr.operands[0])!
			b := sel.vreg_for(m, instr.operands[1])!
			emit << MachineInstr{
				op:   .cmp
				srcs: [reg_operand(a), reg_operand(b)]
			}
			emit << MachineInstr{
				op:      .setcc
				cond:    cond_for(instr.op)!
				dst:     reg_operand(dst)
				has_dst: true
			}
		}
		.br {
			if instr.operands.len != 3 {
				return error('vir: bad branch operands')
			}
			c := sel.vreg_for(m, instr.operands[0])!
			emit << MachineInstr{
				op:   .cmp
				srcs: [reg_operand(c), imm_operand(0)]
			}
			emit << MachineInstr{
				op:     .jcc
				cond:   .ne
				target: block_target(blocks, int(instr.operands[1]))!
			}
			emit << MachineInstr{
				op:     .jmp
				target: block_target(blocks, int(instr.operands[2]))!
			}
		}
		.jmp {
			if instr.operands.len != 1 {
				return error('vir: bad jump operands')
			}
			emit << MachineInstr{
				op:     .jmp
				target: block_target(blocks, int(instr.operands[0]))!
			}
		}
		.switch_ {
			if instr.operands.len < 2 {
				return error('vir: bad switch operands')
			}
			scrut := sel.vreg_for(m, instr.operands[0])!
			mut k := 2
			for k + 1 < instr.operands.len {
				case_val := const_int(m, instr.operands[k])!
				emit << MachineInstr{
					op:   .cmp
					srcs: [reg_operand(scrut), imm_operand(case_val)]
				}
				emit << MachineInstr{
					op:     .jcc
					cond:   .eq
					target: block_target(blocks, int(instr.operands[k + 1]))!
				}
				k += 2
			}
			if (instr.operands.len - 2) % 2 != 0 {
				return error('vir: bad switch case list')
			}
			emit << MachineInstr{
				op:     .jmp
				target: block_target(blocks, int(instr.operands[1]))!
			}
		}
		.ret {
			if instr.operands.len > 1 {
				return error('vir: bad return operands')
			}
			if instr.operands.len == 1 {
				v := sel.vreg_for(m, instr.operands[0])!
				emit << MachineInstr{
					op:      .mov
					dst:     reg_operand(preg(sel.ret_reg))
					has_dst: true
					srcs:    [reg_operand(v)]
				}
			}
			emit << MachineInstr{ op: .ret }
		}
		.call {
			if instr.operands.len == 0 {
				return error('vir: call without callee')
			}
			callee := m.values[int(instr.operands[0])]
			if callee.kind != .func_ref {
				return error('vir: amd64 selector needs direct calls for now')
			}
			mut arg_kinds := []target.Arg{}
			for a in instr.operands[1..] {
				w := int_width(m, m.values[int(a)].typ)!
				arg_kinds << target.Arg{ kind: .int_kind, width: w }
			}
			locs := target.assign_args(sel.cc, arg_kinds)!
			for n, a in instr.operands[1..] {
				v := sel.vreg_for(m, a)!
				loc := locs[n]
				if loc.has_reg {
					emit << MachineInstr{
						op:      .mov
						dst:     reg_operand(preg(loc.reg))
						has_dst: true
						srcs:    [reg_operand(v)]
					}
				} else {
					return error('vir: stack call arguments need frame lowering')
				}
			}
			emit << MachineInstr{
				op:     .call
				symbol: callee.name
			}
			if int(val.typ) != 0 {
				emit << MachineInstr{
					op:      .mov
					dst:     reg_operand(dst)
					has_dst: true
					srcs:    [reg_operand(preg(sel.ret_reg))]
				}
			}
		}
		.load {
			if instr.operands.len != 1 {
				return error('vir: bad load operands')
			}
			p := sel.vreg_for(m, instr.operands[0])!
			emit << MachineInstr{
				op:      .load
				dst:     reg_operand(dst)
				has_dst: true
				srcs:    [mem_operand(p, 0)]
			}
		}
		.store {
			if instr.operands.len != 2 {
				return error('vir: bad store operands')
			}
			v := sel.vreg_for(m, instr.operands[0])!
			p := sel.vreg_for(m, instr.operands[1])!
			emit << MachineInstr{
				op:   .store
				srcs: [mem_operand(p, 0), reg_operand(v)]
			}
		}
		.assign {
			// Phi elimination output: copy source into the phi result.
			if instr.operands.len != 2 {
				return error('vir: bad assign operands')
			}
			d := sel.vreg_for(m, instr.operands[0])!
			a := sel.vreg_for(m, instr.operands[1])!
			emit << MachineInstr{
				op:      .mov
				dst:     reg_operand(d)
				has_dst: true
				srcs:    [reg_operand(a)]
			}
		}
		.bitcast {
			if instr.operands.len != 1 {
				return error('vir: bad bitcast operands')
			}
			a := sel.vreg_for(m, instr.operands[0])!
			_ = int_width(m, instr.typ)!
			emit << MachineInstr{
				op:      .mov
				dst:     reg_operand(dst)
				has_dst: true
				srcs:    [reg_operand(a)]
			}
		}
		else {
			return error('vir: amd64 selector rejects ${instr.op} (run the optimizer; aggregates/floats/memory ops need full ISel)')
		}
	}
	for e in emit {
		mut le := e
		le.line = sel.lines[int(val_id)]
		out.blocks[blk].instrs << le
	}
}
