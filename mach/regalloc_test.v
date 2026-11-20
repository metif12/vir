module mach

import target
import vssa.ssa
import vssa.optimize

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

// A value used in a loop condition is live across the whole loop body. The
// linear scan must not reuse its register for a temporary inside the loop.
fn build_loop_module() &ssa.Module {
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	void_t := ssa.TypeID(0)
	fid := m.new_function('loop', i32_t)
	zero := m.get_or_add_const(i32_t, '0')
	five := m.get_or_add_const(i32_t, '5')
	one := m.get_or_add_const(i32_t, '1')
	entry := m.add_block(fid, 'entry')
	mut i_slot := m.add_instr(.alloca, entry, m.type_store.get_ptr(i32_t), [])
	_ = m.add_instr(.store, entry, void_t, [zero, i_slot])
	mut sum_slot := m.add_instr(.alloca, entry, m.type_store.get_ptr(i32_t), [])
	_ = m.add_instr(.store, entry, void_t, [zero, sum_slot])
	cond_b := m.add_block(fid, 'cond')
	body_b := m.add_block(fid, 'body')
	after_b := m.add_block(fid, 'after')
	m.add_instr(.jmp, entry, void_t, [ssa.ValueID(cond_b)])
	iv := m.add_instr(.load, cond_b, i32_t, [i_slot])
	cmp := m.add_instr(.lt, cond_b, i32_t, [iv, five])
	m.add_instr(.br, cond_b, void_t, [cmp, ssa.ValueID(body_b), ssa.ValueID(after_b)])
	sv := m.add_instr(.load, body_b, i32_t, [sum_slot])
	iv2 := m.add_instr(.load, body_b, i32_t, [i_slot])
	next_sum := m.add_instr(.add, body_b, i32_t, [sv, iv2])
	_ = m.add_instr(.store, body_b, void_t, [next_sum, sum_slot])
	iv3 := m.add_instr(.load, body_b, i32_t, [i_slot])
	next_i := m.add_instr(.add, body_b, i32_t, [iv3, one])
	_ = m.add_instr(.store, body_b, void_t, [next_i, i_slot])
	m.add_instr(.jmp, body_b, void_t, [ssa.ValueID(cond_b)])
	res := m.add_instr(.load, after_b, i32_t, [sum_slot])
	m.add_instr(.ret, after_b, i32_t, [res])
	return m
}

fn test_regalloc_loop_invariant_not_clobbered() {
	mut m := build_loop_module()
	optimize.optimize(mut m)
	t := target.parse_triple('amd64-linux-gnu')!
	mut mm := select_machine(m, t)!
	allocate(mut mm)!
	assert_no_vregs(mm)!
	text := mach_to_text(mm)

	mut const_reg := ''
	for line in text.split_into_lines() {
		tline := line.trim(' ')
		if tline.contains('movi 5') {
			const_reg = tline.split(' = ')[0]
		}
	}
	assert const_reg.len > 0, 'loop-invariant constant was not materialized'

	mut in_body := false
	for line in text.split_into_lines() {
		tline := line.trim(' ')
		if tline.starts_with('@b2') {
			in_body = true
			continue
		}
		if tline.starts_with('@b3') {
			in_body = false
			continue
		}
		if in_body && (tline.contains(' = add ') || tline.contains(' = mov ')) {
			assert tline.split(' = ')[0] != const_reg, 'loop body clobbered the register holding the loop-invariant constant'
		}
	}
}
