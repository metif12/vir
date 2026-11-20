// COFF object writer for vir (M4 step 2, Windows/amd64). Emits a PE/COFF
// relocatable object that MinGW or MSVC linkers can consume. Symbols and
// relocations come from emit.EmitOutput, just like the ELF writer.

module obj

import os

// COFF constants for AMD64.
pub const image_file_machine_amd64 = u16(0x8664)

const image_scn_cnt_code = u32(0x00000020)
const image_scn_cnt_initialized_data = u32(0x00000040)
const image_scn_align_16bytes = u32(0x00500000)
const image_scn_align_8bytes = u32(0x00400000)
const image_scn_mem_execute = u32(0x20000000)
const image_scn_mem_read = u32(0x40000000)
const image_scn_mem_write = u32(0x80000000)

const image_sym_external = u8(2)
const image_sym_type_function = u16(0x20)

// IMAGE_REL_AMD64_REL32: a 32-bit PC-relative field, S + A - P.
pub const image_rel_amd64_rel32 = u16(4)

struct CoffSymbol {
pub mut:
	name    string
	value   u32
	section i16
	typ     u16
	storage u8
}

struct CoffReloc {
	offset u32
	sym    int
	typ    u16
}

// CoffObject is a minimal AMD64 COFF relocatable object.
pub struct CoffObject {
	machine u16
pub mut:
	text_data []u8
	symbols   []CoffSymbol
	relocs    []CoffReloc
}

pub fn CoffObject.new(machine u16) &CoffObject {
	return &CoffObject{ machine: machine }
}

// add_symbol adds or upgrades a defined external symbol in section `section`
// (1-based; 1 = .text). Returns its zero-based symbol-table index.
pub fn (mut e CoffObject) add_symbol(name string, value u32, is_func bool, section i16) int {
	for i, s in e.symbols {
		if s.name == name {
			e.symbols[i].value = value
			e.symbols[i].section = section
			e.symbols[i].typ = if is_func { image_sym_type_function } else { 0 }
			e.symbols[i].storage = image_sym_external
			return i
		}
	}
	e.symbols << CoffSymbol{
		name:    name
		value:   value
		section: section
		typ:     if is_func { image_sym_type_function } else { 0 }
		storage: image_sym_external
	}
	return e.symbols.len - 1
}

// add_undefined adds an external symbol resolved by the linker.
pub fn (mut e CoffObject) add_undefined(name string) int {
	for i, s in e.symbols {
		if s.name == name {
			return i
		}
	}
	e.symbols << CoffSymbol{
		name:    name
		value:   0
		section: 0
		typ:     0
		storage: image_sym_external
	}
	return e.symbols.len - 1
}

// add_text_reloc records a relocation against .text. COFF stores the addend
// in the relocation field itself, so callers must patch the text bytes.
pub fn (mut e CoffObject) add_text_reloc(offset u32, sym_idx int, typ u16) {
	e.relocs << CoffReloc{ offset: offset, sym: sym_idx, typ: typ }
}

fn coff_align(v int, a int) int {
	return if v % a == 0 { v } else { v + (a - v % a) }
}

fn coff_put_u16(mut b []u8, off int, v u16) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
}

fn coff_put_u32(mut b []u8, off int, v u32) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
	b[off + 2] = u8(v >> 16)
	b[off + 3] = u8(v >> 24)
}

// write serializes the object to `path`. It emits .text (with its relocations)
// and an empty .data section, followed by the symbol and string tables.
pub fn (mut e CoffObject) write(path string) ! {
	header_size := 20
	section_header_size := 40
	num_sections := 2

	mut strtab := []u8{len: 4, init: 0} // length word, filled in below
	mut name_offsets := map[string]int{}
	for s in e.symbols {
		if s.name.len > 8 && s.name !in name_offsets {
			name_offsets[s.name] = strtab.len
			strtab << s.name.bytes()
			strtab << u8(0)
		}
	}
	coff_put_u32(mut strtab, 0, u32(strtab.len))

	off_text := coff_align(header_size + num_sections * section_header_size, 16)
	off_reloc := coff_align(off_text + e.text_data.len, 4)
	off_syms := coff_align(off_reloc + e.relocs.len * 10, 4)
	off_strtab := off_syms + e.symbols.len * 18
	mut b := []u8{len: off_strtab + strtab.len, init: 0}

	coff_put_u16(mut b, 0, e.machine)
	coff_put_u16(mut b, 2, u16(num_sections))
	coff_put_u32(mut b, 8, u32(off_syms))
	coff_put_u32(mut b, 12, u32(e.symbols.len))

	// .text section header
	sh1 := header_size
	text_name := [u8(46), u8(116), u8(101), u8(120), u8(116), 0, 0, 0] // ".text"
	for i, c in text_name {
		b[sh1 + i] = c
	}
	coff_put_u32(mut b, sh1 + 16, u32(e.text_data.len))
	coff_put_u32(mut b, sh1 + 20, u32(off_text))
	coff_put_u32(mut b, sh1 + 24, u32(off_reloc))
	coff_put_u16(mut b, sh1 + 32, u16(e.relocs.len))
	coff_put_u32(mut b, sh1 + 36, image_scn_cnt_code | image_scn_align_16bytes |
		image_scn_mem_execute | image_scn_mem_read)

	// .data section header (empty)
	sh2 := header_size + section_header_size
	data_name := [u8(46), u8(100), u8(97), u8(116), u8(97), 0, 0, 0] // ".data"
	for i, c in data_name {
		b[sh2 + i] = c
	}
	coff_put_u32(mut b, sh2 + 36, image_scn_cnt_initialized_data |
		image_scn_align_8bytes | image_scn_mem_read | image_scn_mem_write)

	for i, c in e.text_data {
		b[off_text + i] = c
	}
	for i, r in e.relocs {
		ro := off_reloc + i * 10
		coff_put_u32(mut b, ro, r.offset)
		coff_put_u32(mut b, ro + 4, u32(r.sym))
		coff_put_u16(mut b, ro + 8, r.typ)
	}

	for i, s in e.symbols {
		so := off_syms + i * 18
		if s.name.len > 8 {
			coff_put_u32(mut b, so + 4, u32(name_offsets[s.name]))
		} else {
			for j, c in s.name.bytes() {
				b[so + j] = c
			}
		}
		coff_put_u32(mut b, so + 8, s.value)
		coff_put_u16(mut b, so + 12, u16(s.section))
		coff_put_u16(mut b, so + 14, s.typ)
		b[so + 16] = s.storage
	}
	for i, c in strtab {
		b[off_strtab + i] = c
	}

	os.write_file_array(path, b) or {
		return error('vir: writing COFF object `${path}` failed: ${err.msg()}')
	}
}
