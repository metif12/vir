module main

import vssa.optimize
import vssa.ssa

// test_vssa_smoke_round_trip builds a module with the vendored core,
// optimizes it, and checks the text round-trip plus verifier cleanliness.
// It guards the vendoring: any semantic drift in vssa/ breaks it.
fn test_vssa_smoke_round_trip() {
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	fid := m.new_function('add1', i32_t)
	entry := m.add_block(fid, 'entry')
	one := m.get_or_add_const(i32_t, '1')
	two := m.get_or_add_const(i32_t, '2')
	s := m.add_instr(.add, entry, i32_t, [one, two])
	m.add_instr(.ret, entry, i32_t, [s])
	optimize.optimize(mut m)
	text := ssa.module_to_text(m)!
	assert text.contains('vir 1')
	assert text.contains('add1')
	mut m2 := ssa.module_from_text(text)!
	assert ssa.module_to_text(m2)! == text
	assert optimize.verify(m2).len == 0
}
