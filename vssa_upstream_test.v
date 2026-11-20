module main

// Regressions from the upstream ir_text PR #32555 review (commit 8124eec):
// global values must keep their pointer type, and distinct registered types
// sharing a shape must keep their identities across a text round-trip.

import vssa.ssa
import vssa.optimize

fn test_upstream_global_load_store_round_trip() {
	mut m := ssa.Module.new()
	void_t := ssa.TypeID(0)
	i32_type := m.type_store.get_int(32)
	g := m.add_global('counter', i32_type)
	assert m.type_store.types[m.values[g].typ].kind == .ptr_t

	fid := m.new_function('main', i32_type)
	entry := m.add_block(fid, 'entry')
	loaded := m.add_instr(.load, entry, i32_type, [g])
	one := m.get_or_add_const(i32_type, '1')
	next := m.add_instr(.add, entry, i32_type, [loaded, one])
	m.add_instr(.store, entry, void_t, [next, g])
	m.add_instr(.ret, entry, i32_type, [next])

	text1 := ssa.module_to_text(m)!
	mut m2 := ssa.module_from_text(text1)!
	assert ssa.module_to_text(m2)! == text1
	assert m2.values[g].typ == m.values[g].typ
	assert m2.type_store.types[m2.values[g].typ].kind == .ptr_t
	assert m2.globals.len == 1
	assert m2.globals[0].typ == i32_type
}

fn test_upstream_distinct_empty_structs_round_trip() {
	mut m := ssa.Module.new()
	empty_a := m.type_store.register(ssa.Type{ kind: .struct_t, fields: []ssa.TypeID{} })
	empty_b := m.type_store.register(ssa.Type{ kind: .struct_t, fields: []ssa.TypeID{} })
	assert empty_a != empty_b
	m.c_struct_names[int(empty_a)] = 'EmptyA'
	m.c_struct_names[int(empty_b)] = 'EmptyB'

	text1 := ssa.module_to_text(m)!
	mut m2 := ssa.module_from_text(text1)!
	assert ssa.module_to_text(m2)! == text1
	assert m2.type_store.types.len == m.type_store.types.len
	assert m2.c_struct_names[int(empty_a)] == 'EmptyA'
	assert m2.c_struct_names[int(empty_b)] == 'EmptyB'
}

fn test_upstream_verify_global_load_store_round_trip() {
	mut m := ssa.Module.new()
	void_t := ssa.TypeID(0)
	i32_type := m.type_store.get_int(32)
	g := m.add_global('counter', i32_type)
	fid := m.new_function('main', i32_type)
	entry := m.add_block(fid, 'entry')
	loaded := m.add_instr(.load, entry, i32_type, [g])
	one := m.get_or_add_const(i32_type, '1')
	next := m.add_instr(.add, entry, i32_type, [loaded, one])
	m.add_instr(.store, entry, void_t, [next, g])
	m.add_instr(.ret, entry, i32_type, [next])
	assert optimize.verify(m).len == 0

	text := ssa.module_to_text(m)!
	mut m2 := ssa.module_from_text(text)!
	assert ssa.module_to_text(m2)! == text
	assert optimize.verify(m2).len == 0
}
