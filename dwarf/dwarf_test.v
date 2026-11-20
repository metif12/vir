module dwarf

import emit

fn test_dwarf_info_header_and_payload() {
	syms := [
		emit.EmitSym{ name: 'add', is_func: true, offset: 0, size: 12 },
		emit.EmitSym{ name: 'main', is_func: true, offset: 12, size: 20 },
	]
	secs := build(syms, 'vir 0.1.0', '.', 'vir-module')
	assert secs.info.len > 11
	assert secs.abbrev.len > 3

	unit_len := u32(secs.info[0]) | (u32(secs.info[1]) << 8) |
		(u32(secs.info[2]) << 16) | (u32(secs.info[3]) << 24)
	assert int(unit_len) == secs.info.len - 4
	assert secs.info[4] == 4 // DWARF version
	assert secs.info[10] == 8 // address size
	assert secs.info[secs.info.len - 1] == 0 // NULL terminator
	assert secs.abbrev[secs.abbrev.len - 1] == 0

	text := secs.info.bytestr()
	assert text.contains('vir 0.1.0')
	assert text.contains('vir-module')
	assert text.contains('add')
	assert text.contains('main')

	ab := secs.abbrev.bytestr()
	assert ab.len > 0
	// Both declared DIEs must appear.
	assert secs.abbrev[0] == 1
}

fn test_dwarf_skips_undefined_symbols() {
	syms := [
		emit.EmitSym{ name: 'puts', is_func: true, is_undefined: true },
		emit.EmitSym{ name: 'main', is_func: true, offset: 0, size: 4 },
	]
	secs := build(syms, 'vir', '.', 'm')
	assert secs.info.bytestr().contains('main')
	assert !secs.info.bytestr().contains('puts')
}
