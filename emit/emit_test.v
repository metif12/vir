module emit

import mach
import target
import vssa.optimize
import vssa.ssa

// pr builds an amd64 integer physical register for hand-built modules.
fn pr(index int) mach.Reg {
	return mach.preg(target.PhysReg{ arch: .amd64, index: index })
}

// tiny_module builds a hand-allocated mov/add/ret function:
// rcx = movi 5; rax = mov rcx; rax = add rax, rcx; ret.
fn tiny_module(triple string) mach.MachineModule {
	rax := pr(0)
	rcx := pr(1)
	mut mm := mach.MachineModule{ triple: triple }
	mut f := mach.MachineFunc{ name: 'tiny' }
	mut b := mach.MachineBlock{ id: 0, name: 'entry' }
	b.instrs << mach.MachineInstr{
		op:      .movi
		dst:     mach.reg_operand(rcx)
		has_dst: true
		srcs:    [mach.imm_operand(5)]
	}
	b.instrs << mach.MachineInstr{
		op:      .mov
		dst:     mach.reg_operand(rax)
		has_dst: true
		srcs:    [mach.reg_operand(rcx)]
	}
	b.instrs << mach.MachineInstr{
		op:      .add
		dst:     mach.reg_operand(rax)
		has_dst: true
		srcs:    [mach.reg_operand(rax), mach.reg_operand(rcx)]
	}
	b.instrs << mach.MachineInstr{ op: .ret }
	f.blocks << b
	mm.funcs << f
	return mm
}

// test_emit_golden_mov_add_ret checks the exact bytes of a minimal
// frameless function: prologue, movi, mov, add, epilogue.
fn test_emit_golden_mov_add_ret() {
	mm := tiny_module('amd64-linux-gnu')
	t := target.parse_triple('amd64-linux-gnu')!
	out := emit_amd64(mm, t)!
	expected := [
		u8(0x55), // push rbp
		0x48,
		0x89,
		0xE5, // mov rbp, rsp
		0xB9,
		0x05,
		0x00,
		0x00,
		0x00, // mov ecx, 5
		0x48,
		0x89,
		0xC8, // mov rax, rcx
		0x48,
		0x01,
		0xC8, // add rax, rcx
		0x48,
		0x89,
		0xEC, // mov rsp, rbp
		0x5D, // pop rbp
		0xC3, // ret
	]
	assert out.text == expected
	assert out.data.len == 0
	assert out.rodata.len == 0
	assert out.relocs.len == 0
	assert out.syms.len == 1
	assert out.syms[0].name == 'tiny'
	assert out.syms[0].is_func
	assert !out.syms[0].is_undefined
	assert out.syms[0].offset == 0
	assert out.syms[0].size == u32(expected.len)
}

// test_emit_golden_frame_slot_call checks frame sizing, slot binding and
// the call relocation: one spill slot forces a 16-byte frame, and the call
// to `ext` becomes an undefined symbol plus a PLT32 reloc (addend -4).
fn test_emit_golden_frame_slot_call() {
	rax := pr(0)
	mut mm := mach.MachineModule{ triple: 'amd64-linux-gnu' }
	mut f := mach.MachineFunc{ name: 'caller', stack_slots: 1 }
	mut b := mach.MachineBlock{ id: 0, name: 'entry' }
	b.instrs << mach.MachineInstr{
		op:      .movi
		dst:     mach.reg_operand(rax)
		has_dst: true
		srcs:    [mach.imm_operand(7)]
	}
	b.instrs << mach.MachineInstr{
		op:      .mov
		dst:     mach.slot_operand(0)
		has_dst: true
		srcs:    [mach.reg_operand(rax)]
	}
	b.instrs << mach.MachineInstr{ op: .call, symbol: 'ext' }
	b.instrs << mach.MachineInstr{
		op:      .mov
		dst:     mach.reg_operand(rax)
		has_dst: true
		srcs:    [mach.slot_operand(0)]
	}
	b.instrs << mach.MachineInstr{ op: .ret }
	f.blocks << b
	mm.funcs << f
	t := target.parse_triple('amd64-linux-gnu')!
	out := emit_amd64(mm, t)!
	expected := [
		u8(0x55), // push rbp
		0x48,
		0x89,
		0xE5, // mov rbp, rsp
		0x48,
		0x83,
		0xEC,
		0x10, // sub rsp, 16
		0xB8,
		0x07,
		0x00,
		0x00,
		0x00, // mov eax, 7
		0x48,
		0x89,
		0x45,
		0xF8, // mov [rbp-8], rax
		0xE8,
		0x00,
		0x00,
		0x00,
		0x00, // call ext (disp relocated)
		0x48,
		0x8B,
		0x45,
		0xF8, // mov rax, [rbp-8]
		0x48,
		0x89,
		0xEC, // mov rsp, rbp
		0x5D, // pop rbp
		0xC3, // ret
	]
	assert out.text == expected
	assert out.syms.len == 2
	assert out.syms[0].name == 'caller'
	assert !out.syms[0].is_undefined
	assert out.syms[0].size == u32(expected.len)
	assert out.syms[1].name == 'ext'
	assert out.syms[1].is_func
	assert out.syms[1].is_undefined
	assert out.relocs.len == 1
	assert out.relocs[0].offset == 18 // the call's disp32 field
	assert out.relocs[0].sym == 1
	assert out.relocs[0].typ == r_x86_64_plt32
	assert out.relocs[0].addend == -4
}

// test_emit_golden_branch_patching checks rel32 back-patching: a forward
// jmp (displacement 0) and a backward jcc ne (displacement -14).
fn test_emit_golden_branch_patching() {
	rax := pr(0)
	rcx := pr(1)
	mut mm := mach.MachineModule{ triple: 'amd64-linux-gnu' }
	mut f := mach.MachineFunc{ name: 'loop' }
	mut b0 := mach.MachineBlock{ id: 0, name: 'entry' }
	b0.instrs << mach.MachineInstr{
		op:      .movi
		dst:     mach.reg_operand(rcx)
		has_dst: true
		srcs:    [mach.imm_operand(3)]
	}
	b0.instrs << mach.MachineInstr{ op: .jmp, target: 1 }
	mut b1 := mach.MachineBlock{ id: 1, name: 'body' }
	b1.instrs << mach.MachineInstr{
		op:      .sub
		dst:     mach.reg_operand(rcx)
		has_dst: true
		srcs:    [mach.reg_operand(rcx), mach.imm_operand(1)]
	}
	b1.instrs << mach.MachineInstr{
		op:   .cmp
		srcs: [mach.reg_operand(rcx), mach.imm_operand(0)]
	}
	b1.instrs << mach.MachineInstr{ op: .jcc, cond: .ne, target: 1 }
	b1.instrs << mach.MachineInstr{
		op:      .mov
		dst:     mach.reg_operand(rax)
		has_dst: true
		srcs:    [mach.reg_operand(rcx)]
	}
	b1.instrs << mach.MachineInstr{ op: .ret }
	f.blocks << b0
	f.blocks << b1
	mm.funcs << f
	t := target.parse_triple('amd64-linux-gnu')!
	out := emit_amd64(mm, t)!
	expected := [
		u8(0x55), // push rbp
		0x48,
		0x89,
		0xE5, // mov rbp, rsp
		0xB9,
		0x03,
		0x00,
		0x00,
		0x00, // mov ecx, 3
		0xE9,
		0x00,
		0x00,
		0x00,
		0x00, // jmp @b1 (rel32 = 0)
		0x48,
		0x83,
		0xE9,
		0x01, // sub rcx, 1
		0x48,
		0x83,
		0xF9,
		0x00, // cmp rcx, 0
		0x0F,
		0x85,
		0xF2,
		0xFF,
		0xFF,
		0xFF, // jne @b1 (rel32 = -14)
		0x48,
		0x89,
		0xC8, // mov rax, rcx
		0x48,
		0x89,
		0xEC, // mov rsp, rbp
		0x5D, // pop rbp
		0xC3, // ret
	]
	assert out.text == expected
	assert out.relocs.len == 0
	assert out.syms.len == 1
	assert out.syms[0].size == u32(expected.len)
}

// test_emit_win64_shadow_space checks that the Win64 convention reserves
// 32 bytes of shadow space in the frame even without spill slots.
fn test_emit_win64_shadow_space() {
	mm := tiny_module('amd64-windows-msvc')
	t := target.parse_triple('amd64-windows-msvc')!
	out := emit_amd64(mm, t)!
	expected := [
		u8(0x55), // push rbp
		0x48,
		0x89,
		0xE5, // mov rbp, rsp
		0x48,
		0x83,
		0xEC,
		0x20, // sub rsp, 32 (shadow space)
		0xB9,
		0x05,
		0x00,
		0x00,
		0x00, // mov ecx, 5
		0x48,
		0x89,
		0xC8, // mov rax, rcx
		0x48,
		0x01,
		0xC8, // add rax, rcx
		0x48,
		0x89,
		0xEC, // mov rsp, rbp
		0x5D, // pop rbp
		0xC3, // ret
	]
	assert out.text == expected
	assert out.syms.len == 1
	assert out.syms[0].size == u32(expected.len)
}

// test_emit_end_to_end runs the full pipeline (optimize, isel, regalloc,
// emit) on a small SSA module and checks the output is sane: non-empty
// text and a defined global `main` function symbol covering it.
fn test_emit_end_to_end() {
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	fid := m.new_function('main', i32_t)
	a := m.add_value(.argument, i32_t, 'x', 0)
	b := m.add_value(.argument, i32_t, 'y', 1)
	m.func_add_param(fid, a)
	m.func_add_param(fid, b)
	entry := m.add_block(fid, 'entry')
	s := m.add_instr(.add, entry, i32_t, [a, b])
	m.add_instr(.ret, entry, i32_t, [s])
	optimize.optimize(mut m)
	t := target.parse_triple('amd64-linux-gnu')!
	mut mm := mach.select_machine(m, t)!
	mach.allocate(mut mm)!
	mach.assert_no_vregs(mm)!
	out := emit_amd64(mm, t)!
	assert out.text.len > 0
	assert out.text[0] == 0x55 // push rbp prologue
	mut found := false
	for sym in out.syms {
		if sym.name == 'main' {
			found = true
			assert sym.is_func
			assert !sym.is_undefined
			assert sym.offset == 0
			assert int(sym.size) == out.text.len
		}
	}
	assert found
}

// test_emit_three_operand_imul checks that dst = reg*imm emits a single
// imul (no prologue mov): 48 6B C1 03 = imul rax, rcx, 3.
fn test_emit_three_operand_imul() {
	rax := pr(0)
	rcx := pr(1)
	mut mm := mach.MachineModule{ triple: 'amd64-linux-gnu' }
	mut f := mach.MachineFunc{ name: 'mul' }
	mut b := mach.MachineBlock{ id: 0, name: 'entry' }
	b.instrs << mach.MachineInstr{
		op:      .imul
		dst:     mach.reg_operand(rax)
		has_dst: true
		srcs:    [mach.reg_operand(rcx), mach.imm_operand(3)]
	}
	b.instrs << mach.MachineInstr{ op: .ret }
	f.blocks << b
	mm.funcs << f
	t := target.parse_triple('amd64-linux-gnu')!
	out := emit_amd64(mm, t)!
	body := [u8(0x48), 0x6B, 0xC1, 0x03] // imul rax, rcx, 3
	assert out.text[4..8] == body
	// No extra mov opcode between prologue and the imul.
	assert out.text.len == 4 + 4 + 5 // prologue + imul + mov rsp/rbp + pop + ret
}
