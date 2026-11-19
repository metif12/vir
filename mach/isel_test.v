module mach

import os
import target
import vssa.optimize
import vssa.ssa

// read_corpus_file reads one golden input from the shared testdata dir.
fn read_corpus_file(name string) string {
	return os.read_file(os.join_path(@VMODROOT, 'testdata', name)) or {
		panic('cannot read corpus file ${name}: ${err.msg()}')
	}
}

fn test_isel_golden_simple_add() {
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
	t := target.parse_triple('amd64-linux-gnu')!
	mm := select_machine(m, t)!
	text := mach_to_text(mm)
	expected := 'machine amd64-linux-gnu\n' + 'func \$add1 :\n' + '@b0 :\n'
		+ '  %v1 = mov rdi\n' + '  %v2 = mov rsi\n' + '  %v0 = mov %v1\n'
		+ '  %v0 = add %v0, %v2\n' + '  rax = mov %v0\n' + '  ret\n'
	assert text == expected
}

fn test_isel_golden_simple_add_arm64() {
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
	t := target.parse_triple('aarch64-linux-gnu')!
	mm := select_machine(m, t)!
	text := mach_to_text(mm)
	expected := 'machine arm64-linux-gnu\n' + 'func \$add1 :\n' + '@b0 :\n'
		+ '  %v1 = mov x0\n' + '  %v2 = mov x1\n' + '  %v0 = mov %v1\n'
		+ '  %v0 = add %v0, %v2\n' + '  x0 = mov %v0\n' + '  ret\n'
	assert text == expected
}

fn test_isel_smoke_corpus_end_to_end() {
	src := read_corpus_file('smoke.vir')
	mut m := ssa.module_from_text(src)!
	optimize.optimize(mut m)
	assert optimize.verify(m).len == 0
	for triple in ['amd64-linux-gnu', 'amd64-windows-msvc', 'aarch64-linux-gnu'] {
		t := target.parse_triple(triple)!
		mm := select_machine(m, t)!
		text := mach_to_text(mm)
		assert text.contains('func \$main :')
		assert text.contains('jcc')
		assert !text.contains('phi ')
		mm2 := select_machine(m, t)!
		assert mach_to_text(mm2) == text
	}
}

fn test_isel_rejects_phi() {
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	fid := m.new_function('f', i32_t)
	entry := m.add_block(fid, 'entry')
	zero := m.get_or_add_const(i32_t, '0')
	phi := m.add_instr(.phi, entry, i32_t, [zero, ssa.ValueID(entry)])
	m.add_instr(.ret, entry, i32_t, [phi])
	t := target.parse_triple('amd64-linux-gnu')!
	select_amd64(m, t) or {
		assert err.msg().contains('phi')
		return
	}
	assert false, 'expected phi rejection'
}

fn test_isel_rejects_wrong_arch() {
	mut m := ssa.Module.new()
	t := target.parse_triple('riscv64-linux-gnu') or {
		assert err.msg().contains('unsupported arch')
		return
	}
	select_machine(m, t) or {
		assert err.msg().contains('amd64')
		return
	}
	assert false, 'expected arch rejection'
}
