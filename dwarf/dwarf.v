module dwarf

// Minimal DWARF 4 producer for vir: one compile unit with a subprogram DIE
// per defined function plus a line table. Debug sections are non-allocatable
// and contain no relocations because a function's address is its
// section-relative offset. Variable locations are post-v1 work.

import emit

const tag_compile_unit = 0x11
const tag_subprogram = 0x2e

const at_name = 0x03
const at_language = 0x13
const at_comp_dir = 0x1b
const at_producer = 0x25
const at_low_pc = 0x11
const at_high_pc = 0x12
const at_decl_line = 0x3b
const at_external = 0x3f
const at_stmt_list = 0x10

const form_addr = 0x01
const form_data2 = 0x05
const form_data4 = 0x06
const form_string = 0x08
const form_data1 = 0x0b
const form_flag_present = 0x19
const form_sec_offset = 0x17

// Line program opcodes used by build_line.
const lns_copy = 0x01
const lns_advance_pc = 0x02
const lns_advance_line = 0x03
const lne_end_sequence = 0x01

const dw_lang_c = 0x02

pub struct DwarfSections {
pub:
	info   []u8
	abbrev []u8
	line   []u8
}

fn put_u16(mut b []u8, v u16) {
	b << u8(v)
	b << u8(v >> 8)
}

fn put_u32(mut b []u8, v u32) {
	for i in 0 .. 4 {
		b << u8(v >> (8 * i))
	}
}

fn put_u64(mut b []u8, v u64) {
	for i in 0 .. 8 {
		b << u8(v >> (8 * i))
	}
}

fn put_pair(mut b []u8, a int, f int) {
	// All attribute and form codes used here are below 0x80, so ULEB128 is
	// a single byte.
	b << u8(a)
	b << u8(f)
}

fn put_uleb(mut b []u8, v u64) {
	mut x := v
	for {
		mut byte := u8(x & 0x7f)
		x >>= 7
		if x != 0 {
			byte |= 0x80
		}
		b << byte
		if x == 0 {
			break
		}
	}
}

fn put_sleb(mut b []u8, v i64) {
	mut x := v
	for {
		mut byte := u8(x & 0x7f)
		x >>= 7
		sign := (byte & 0x40) != 0
		done := (x == 0 && !sign) || (x == -1 && sign)
		if !done {
			byte |= 0x80
		}
		b << byte
		if done {
			break
		}
	}
}

pub fn build(syms []emit.EmitSym, rows []emit.LineRow, producer string, comp_dir string, cu_name string) DwarfSections {
	mut ab := []u8{}
	// Abbrev 1: DW_TAG_compile_unit, has children.
	ab << u8(1)
	ab << u8(tag_compile_unit)
	ab << u8(1)
	put_pair(mut ab, at_producer, form_string)
	put_pair(mut ab, at_language, form_data1)
	put_pair(mut ab, at_name, form_string)
	put_pair(mut ab, at_comp_dir, form_string)
	put_pair(mut ab, at_low_pc, form_addr)
	put_pair(mut ab, at_high_pc, form_data4)
	put_pair(mut ab, at_stmt_list, form_sec_offset)
	ab << u8(0)
	ab << u8(0)
	// Abbrev 2: DW_TAG_subprogram, no children.
	ab << u8(2)
	ab << u8(tag_subprogram)
	ab << u8(0)
	put_pair(mut ab, at_name, form_string)
	put_pair(mut ab, at_decl_line, form_data2)
	put_pair(mut ab, at_low_pc, form_addr)
	put_pair(mut ab, at_high_pc, form_data4)
	put_pair(mut ab, at_external, form_flag_present)
	ab << u8(0)
	ab << u8(0)
	ab << u8(0) // end of abbreviation table

	mut die := []u8{}
	die << u8(1)
	die << producer.bytes()
	die << u8(0)
	die << u8(dw_lang_c)
	die << cu_name.bytes()
	die << u8(0)
	die << comp_dir.bytes()
	die << u8(0)
	// DW_AT_low_pc / high_pc describe the whole compilation unit; use the
	// first defined function's range.
	mut low := u64(0)
	mut high := u32(0)
	for s in syms {
		if s.is_func && !s.is_undefined {
			low = u64(s.offset)
			high = s.size
			break
		}
	}
	put_u64(mut die, low)
	put_u32(mut die, high)
	// DW_AT_stmt_list is the section offset of this CU's line program.
	// vir emits a single CU, so it is always zero.
	put_u32(mut die, 0)

	for s in syms {
		if !s.is_func || s.is_undefined {
			continue
		}
		die << u8(2)
		die << s.name.bytes()
		die << u8(0)
		put_u16(mut die, 1)
		put_u64(mut die, u64(s.offset))
		put_u32(mut die, s.size)
		// DW_AT_external uses DW_FORM_flag_present: the abbreviation itself
		// carries the truth value, so no byte is emitted here.
	}
	die << u8(0) // end of compile-unit children

	line := build_line(rows, comp_dir, cu_name)

	mut info := []u8{}
	// unit_length excludes this 4-byte field itself.
	put_u32(mut info, u32(2 + 4 + 1 + die.len))
	put_u16(mut info, 4) // DWARF version
	put_u32(mut info, 0) // offset into .debug_abbrev
	info << u8(8) // address size
	info << die

	return DwarfSections{ info: info, abbrev: ab, line: line }
}

// build_line emits a DWARF 4 .debug_line section for one compilation unit:
// one file entry plus one row per address, encoded with advance_pc /
// advance_line / copy only (no special opcodes). An empty row list yields
// a header plus end_sequence, which is still a valid program.
fn build_line(rows []emit.LineRow, comp_dir string, file string) []u8 {
	mut head := []u8{}
	head << u8(1) // minimum_instruction_length
	head << u8(1) // maximum_operations_per_instruction (DWARF 4)
	head << u8(1) // default_is_stmt
	head << u8(0xfb) // line_base -5 as a byte
	head << u8(14) // line_range
	head << u8(13) // opcode_base
	// Standard opcode operand counts for DW_LNS_copy..DW_LNS_set_isa.
	head << [u8(0), u8(1), u8(1), u8(1), u8(1), u8(0), u8(0), u8(0), u8(1), u8(0), u8(0), u8(1)]
	head << comp_dir.bytes()
	head << u8(0)
	head << u8(0) // end of include directories
	head << file.bytes()
	head << u8(0)
	put_uleb(mut head, 1) // directory index (1-based)
	put_uleb(mut head, 0) // mtime
	put_uleb(mut head, 0) // size
	head << u8(0) // end of file names

	mut prog := []u8{}
	mut addr := u64(0)
	mut line := 1
	for r in rows {
		if u64(r.offset) < addr || r.line <= 0 {
			continue
		}
		prog << u8(lns_advance_pc)
		put_uleb(mut prog, u64(r.offset) - addr)
		prog << u8(lns_advance_line)
		put_sleb(mut prog, i64(r.line - line))
		prog << u8(lns_copy)
		addr = u64(r.offset)
		line = r.line
	}
	// DW_LNE_end_sequence: extended opcode 0x00, length 1, sub-opcode 0x01.
	prog << u8(0)
	put_uleb(mut prog, 1)
	prog << u8(lne_end_sequence)

	mut body := []u8{}
	put_u16(mut body, 4) // DWARF version
	put_u32(mut body, u32(head.len))
	body << head
	body << prog
	mut out := []u8{}
	put_u32(mut out, u32(body.len))
	out << body
	return out
}
