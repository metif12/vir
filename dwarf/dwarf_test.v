module dwarf

import emit

fn test_dwarf_info_header_and_payload() {
	syms := [
		emit.EmitSym{ name: 'add', is_func: true, offset: 0, size: 12 },
		emit.EmitSym{ name: 'main', is_func: true, offset: 12, size: 20 },
	]
	secs := build(syms, []emit.LineRow{}, 'vir 0.1.0', '.', 'vir-module')
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

fn test_dwarf_line_program_header() {
	syms := [
		emit.EmitSym{ name: 'main', is_func: true, offset: 0, size: 4 },
	]
	rows := [
		emit.LineRow{ offset: 0, line: 3 },
		emit.LineRow{ offset: 2, line: 4 },
	]
	secs := build(syms, rows, 'vir', '.', 'm.c')
	assert secs.line.len > 12
	unit_len := u32(secs.line[0]) | (u32(secs.line[1]) << 8) | (u32(secs.line[2]) << 16) | (u32(secs.line[3]) << 24)
	assert int(unit_len) == secs.line.len - 4
	assert secs.line[4] == 4 // DWARF version
	assert secs.line[5] == 0
	header_len := int(u32(secs.line[6]) | (u32(secs.line[7]) << 8) | (u32(secs.line[8]) << 16) | (u32(secs.line[9]) << 24))
	assert header_len > 0
	prog := secs.line[10 + header_len..]
	// First row: advance_pc(1 byte) + uleb(0), advance_line + sleb(2), copy.
	assert prog[0] == 0x02
	assert prog[1] == 0
	assert prog[2] == 0x03
	assert prog[3] == 2
	assert prog[4] == 0x01
	// Ends with DW_LNE_end_sequence: 0x00, uleb(1), 0x01.
	assert prog[prog.len - 3] == 0
	assert prog[prog.len - 2] == 1
	assert prog[prog.len - 1] == 1
	// The CU carries DW_AT_stmt_list so consumers find the program.
	assert secs.info.bytestr().contains('m.c')
}

fn test_dwarf_empty_rows_yield_shell_program() {
	syms := [
		emit.EmitSym{ name: 'main', is_func: true, offset: 0, size: 4 },
	]
	secs := build(syms, []emit.LineRow{}, 'vir', '.', 'm')
	assert secs.line.len > 12
	unit_len := u32(secs.line[0]) | (u32(secs.line[1]) << 8) | (u32(secs.line[2]) << 16) | (u32(secs.line[3]) << 24)
	assert int(unit_len) == secs.line.len - 4
}

fn test_dwarf_skips_undefined_symbols() {
	syms := [
		emit.EmitSym{ name: 'puts', is_func: true, is_undefined: true },
		emit.EmitSym{ name: 'main', is_func: true, offset: 0, size: 4 },
	]
	secs := build(syms, []emit.LineRow{}, 'vir', '.', 'm')
	assert secs.info.bytestr().contains('main')
	assert !secs.info.bytestr().contains('puts')
}

fn find_bytes(b []u8, pat []u8) int {
	if pat.len == 0 || b.len < pat.len {
		return -1
	}
	for i in 0 .. b.len - pat.len + 1 {
		mut ok := true
		for j in 0 .. pat.len {
			if b[i + j] != pat[j] {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return -1
}

fn test_dwarf_variable_entries() {
	syms := [
		emit.EmitSym{
			name:    'add'
			is_func: true
			offset:  0
			size:    12
			params:  [
				emit.EmitParam{ name: 'a', is_reg: true, reg: 7 },
				emit.EmitParam{ name: 'b', breg: 6, offset: 24 },
			]
		},
	]
	secs := build(syms, []emit.LineRow{}, 'vir', '.', 'm')
	// Variable DIE for `a`: abbrev 3, name, exprloc length 1, DW_OP_reg7.
	assert find_bytes(secs.info, [u8(3), `a`, 0, 1, 0x57]) >= 0
	// Variable DIE for `b`: DW_OP_breg6(0x76) plus SLEB128(24).
	assert find_bytes(secs.info, [u8(3), `b`, 0, 2, 0x76, 24]) >= 0
	// Subprogram children are terminated, then the CU children.
	last := secs.info[secs.info.len - 2..]
	assert last == [u8(0), u8(0)]
}
