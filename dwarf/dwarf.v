module dwarf

// Minimal DWARF 4 producer for vir: one compile unit with a subprogram DIE
// per defined function. Debug sections are non-allocatable and contain no
// relocations because a function's address is its section-relative offset.
// Line tables and variable locations are post-v1 work.

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

const form_addr = 0x01
const form_data2 = 0x05
const form_data4 = 0x06
const form_string = 0x08
const form_data1 = 0x0b
const form_flag_present = 0x19

const dw_lang_c = 0x02

pub struct DwarfSections {
pub:
	info   []u8
	abbrev []u8
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

pub fn build(syms []emit.EmitSym, producer string, comp_dir string, cu_name string) DwarfSections {
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

	mut info := []u8{}
	// unit_length excludes this 4-byte field itself.
	put_u32(mut info, u32(2 + 4 + 1 + die.len))
	put_u16(mut info, 4) // DWARF version
	put_u32(mut info, 0) // offset into .debug_abbrev
	info << u8(8) // address size
	info << die

	return DwarfSections{ info: info, abbrev: ab }
}
