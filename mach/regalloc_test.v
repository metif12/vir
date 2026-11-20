module mach

import target
import vssa.ssa

fn build_add_module() &ssa.Module {
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	fid := m.new_function('add1', i32_t)
	a := m.add_value(.argument, i32_t, 'x', 0)
	b := m.add_value(.argument, i32_t, 'y', 1)
	m.func_add_param(fid, a)
	m.func_add_param(fid, b)
	entry := m.add_block(fid, 'entry')
	s := m.add_instr(.add, entry, i32_t, [a, b])
	m.add_instr(.ret, entry, i32_t, [s])
	return m
}

fn test_regalloc_no_spill_small() {
	mut m := build_add_module()
	t := target.parse_triple('amd64-linux-gnu')!
	mut mm := select_machine(m, t)!
	allocate(mut mm)!
	assert_no_vregs(mm)!
	text := mach_to_text(mm)
	expected := 'machine amd64-linux-gnu\n' + 'func \$add1 :\n' + '@b0 :\n' +
		'  rcx = mov rdi\n' + '  rdx = mov rsi\n' + '  rsi = mov rcx\n' +
		'  rsi = add rsi, rdx\n' + '  rax = mov rsi\n' + '  ret\n'
	assert text == expected
	assert mm.funcs[0].stack_slots == 0
}

fn test_regalloc_no_spill_arm64() {
	mut m := build_add_module()
	t := target.parse_triple('aarch64-linux-gnu')!
	mut mm := select_machine(m, t)!
	allocate(mut mm)!
	assert_no_vregs(mm)!
	text := mach_to_text(mm)
	expected := 'machine arm64-linux-gnu\n' + 'func \$add1 :\n' + '@b0 :\n' +
		'  x1 = mov x0\n' + '  x2 = mov x1\n' + '  x3 = mov x1\n' +
		'  x3 = add x3, x2\n' + '  x0 = mov x3\n' + '  ret\n'
	assert text == expected
	assert mm.funcs[0].stack_slots == 0
}

fn test_regalloc_spills_under_pressure() {
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	fid := m.new_function('sum12', i32_t)
	mut ps := []ssa.ValueID{}
	for n in 0 .. 12 {
		p := m.add_value(.argument, i32_t, 'a${n}', n)
		m.func_add_param(fid, p)
		ps << p
	}
	entry := m.add_block(fid, 'entry')
	mut acc := m.add_instr(.add, entry, i32_t, [ps[0], ps[1]])
	for n in 2 .. 12 {
		acc = m.add_instr(.add, entry, i32_t, [acc, ps[n]])
	}
	m.add_instr(.ret, entry, i32_t, [acc])
	t := target.parse_triple('amd64-linux-gnu')!
	mut mm := select_machine(m, t)!
	allocate(mut mm)!
	assert_no_vregs(mm)!
	assert mm.funcs[0].stack_slots > 0
	assert !mach_to_text(mm).contains('%v')
}

fn test_regalloc_spills_across_calls() {
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	callee := m.new_function('ext', i32_t)
	centry := m.add_block(callee, 'entry')
	m.add_instr(.ret, centry, i32_t, [m.get_or_add_const(i32_t, '0')])
	fid := m.new_function('main', i32_t)
	x := m.add_value(.argument, i32_t, 'x', 0)
	m.func_add_param(fid, x)
	entry := m.add_block(fid, 'entry')
	ref := m.add_value(.func_ref, i32_t, 'ext', callee)
	rv := m.add_instr(.call, entry, i32_t, [ref, x])
	y := m.add_instr(.add, entry, i32_t, [rv, x])
	m.add_instr(.ret, entry, i32_t, [y])
	t := target.parse_triple('amd64-linux-gnu')!
	mut mm := select_machine(m, t)!
	allocate(mut mm)!
	assert_no_vregs(mm)!
	// x is defined before the call and used after it, so it spills.
	// The call result is produced after the call, so it takes a register.
	assert mm.funcs[1].stack_slots == 1
}

fn test_regalloc_spilled_pointer_base_binds_frame() {
	mut m := ssa.Module.new()
	void_t := ssa.TypeID(0)
	i32_t := m.type_store.get_int(32)
	callee := m.new_function('ext', void_t)
	centry := m.add_block(callee, 'entry')
	m.add_instr(.ret, centry, void_t, [])
	fid := m.new_function('main', i32_t)
	x := m.add_value(.argument, i32_t, 'x', 0)
	m.func_add_param(fid, x)
	entry := m.add_block(fid, 'entry')
	one := m.get_or_add_const(i32_t, '1')
	ref := m.add_value(.func_ref, void_t, 'ext', callee)
	_ = m.add_instr(.call, entry, void_t, [ref, x])
	_ = m.add_instr(.store, entry, void_t, [one, x])
	m.add_instr(.ret, entry, i32_t, [one])
	t := target.parse_triple('amd64-linux-gnu')!
	mut mm := select_machine(m, t)!
	allocate(mut mm)!
	assert_no_vregs(mm)!
	// x (used by the call and the store) and the constant (materialized
	// before the call, used after) both cross it, so both spill.
	assert mm.funcs[1].stack_slots == 2
	text := mach_to_text(mm)
	assert text.contains('[fp-8]')
}
