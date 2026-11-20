// MachO64 object writer for vir (M4 step 3, macOS/amd64). Produces a
// MH_OBJECT file thatlld/ld64 can consume. Execution cannot be validated on
// this host; correctness is checked structurally with llvm-objdump/readobj.

module obj

import os

// CPU_TYPE_X86_64 and its generic subtype.
pub const cputype_x86_64 = u32(0x01000007)
pub const cpusubtype_x86_64_all = u32(3)

const macho_magic = u32(0xfeedfacf)
const mh_object = 1
const lc_segment_64 = 0x19
const lc_symtab = 0x2

const s_regular = 0x0
const s_attr_pure_instructions = u32(0x80000000)
const s_attr_some_instructions = 0x00000400

const n_ext = 0x01
const n_sect = 0x0e
const n_undf = 0x00

// x86_64 MachO relocation types.
const x86_64_reloc_signed = 1
const x86_64_reloc_branch = 2

struct MachSymbol {
pub mut:
	name         string
	value        u64
	section      u8
	is_undefined bool
}

struct MachReloc {
	offset u32
	sym    int
	typ    u8
}

// MachObject is a minimal x86-64 MachO relocatable object.
pub struct MachObject {
pub mut:
	text_data []u8
	symbols   []MachSymbol
	relocs    []MachReloc
}

pub fn MachObject.new() &MachObject {
	return &MachObject{}
}

pub fn (mut e MachObject) add_symbol(name string, value u64, is_func bool) int {
	_ = is_func
	for i, s in e.symbols {
		if s.name == name {
			e.symbols[i].value = value
			e.symbols[i].section = 1
			e.symbols[i].is_undefined = false
			return i
		}
	}
	e.symbols << MachSymbol{ name: name, value: value, section: 1 }
	return e.symbols.len - 1
}

pub fn (mut e MachObject) add_undefined(name string) int {
	for i, s in e.symbols {
		if s.name == name {
			return i
		}
	}
	e.symbols << MachSymbol{ name: name, section: 0, is_undefined: true }
	return e.symbols.len - 1
}

// typ is an ELF relocation type: 4 = PLT32 (branch), 2 = PC32 (signed).
pub fn (mut e MachObject) add_text_reloc(offset u32, sym_idx int, typ int) {
	mut rtype := u8(x86_64_reloc_signed)
	if typ == 4 {
		rtype = u8(x86_64_reloc_branch)
	}
	e.relocs << MachReloc{ offset: offset, sym: sym_idx, typ: rtype }
}

fn macho_align(v int, a int) int {
	return if v % a == 0 { v } else { v + (a - v % a) }
}

fn macho_put16(mut b []u8, off int, v u16) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
}

fn macho_put32(mut b []u8, off int, v u32) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
	b[off + 2] = u8(v >> 16)
	b[off + 3] = u8(v >> 24)
}

fn macho_put64(mut b []u8, off int, v u64) {
	for i in 0 .. 8 {
		b[off + i] = u8(v >> (8 * i))
	}
}

fn macho_name(mut b []u8, off int, name string, fixed int) {
	for i in 0 .. fixed {
		b[off + i] = 0
	}
	for i, c in name.bytes() {
		if i >= fixed {
			break
		}
		b[off + i] = c
	}
}

// write serializes the object to `path`.
pub fn (mut e MachObject) write(path string) ! {
	header_size := 32
	segment_cmd_size := 72 + 80 // one section
	symtab_cmd_size := 24
	sizeofcmds := segment_cmd_size + symtab_cmd_size

	off_text := macho_align(header_size + sizeofcmds, 16)
	off_reloc := macho_align(off_text + e.text_data.len, 4)
	off_syms := macho_align(off_reloc + e.relocs.len * 8, 8)

	mut strtab := []u8{len: 1, init: 0} // MachO string tables start with NUL
	mut name_off := map[string]int{}
	for s in e.symbols {
		name_off[s.name] = strtab.len
		strtab << s.name.bytes()
		strtab << u8(0)
	}
	off_str := off_syms + e.symbols.len * 16

	mut b := []u8{len: off_str + strtab.len, init: 0}

	// mach_header_64
	macho_put32(mut b, 0, macho_magic)
	macho_put32(mut b, 4, cputype_x86_64)
	macho_put32(mut b, 8, cpusubtype_x86_64_all)
	macho_put32(mut b, 12, mh_object)
	macho_put32(mut b, 16, 2) // LC_SEGMENT_64 + LC_SYMTAB
	macho_put32(mut b, 20, u32(sizeofcmds))
	macho_put32(mut b, 24, 0)
	macho_put32(mut b, 28, 0)

	// LC_SEGMENT_64
	seg := header_size
	macho_put32(mut b, seg, lc_segment_64)
	macho_put32(mut b, seg + 4, u32(segment_cmd_size))
	macho_name(mut b, seg + 8, '__TEXT', 16)
	macho_put64(mut b, seg + 24, 0)
	macho_put64(mut b, seg + 32, u64(e.text_data.len))
	macho_put64(mut b, seg + 40, u64(off_text))
	macho_put64(mut b, seg + 48, u64(e.text_data.len))
	macho_put32(mut b, seg + 56, 7) // maxprot
	macho_put32(mut b, seg + 60, 5) // initprot: r-x
	macho_put32(mut b, seg + 64, 1) // one section
	macho_put32(mut b, seg + 68, 0)

	// section_64 __text
	sec := seg + 72
	macho_name(mut b, sec, '__text', 16)
	macho_name(mut b, sec + 16, '__TEXT', 16)
	macho_put64(mut b, sec + 32, 0)
	macho_put64(mut b, sec + 40, u64(e.text_data.len))
	macho_put32(mut b, sec + 48, u32(off_text))
	macho_put32(mut b, sec + 52, 4) // 16-byte alignment
	macho_put32(mut b, sec + 56, u32(off_reloc))
	macho_put32(mut b, sec + 60, u32(e.relocs.len))
	macho_put32(mut b, sec + 64, s_regular | s_attr_pure_instructions |
		s_attr_some_instructions)

	// LC_SYMTAB
	symcmd := header_size + segment_cmd_size
	macho_put32(mut b, symcmd, lc_symtab)
	macho_put32(mut b, symcmd + 4, u32(symtab_cmd_size))
	macho_put32(mut b, symcmd + 8, u32(off_syms))
	macho_put32(mut b, symcmd + 12, u32(e.symbols.len))
	macho_put32(mut b, symcmd + 16, u32(off_str))
	macho_put32(mut b, symcmd + 20, u32(strtab.len))

	for i, c in e.text_data {
		b[off_text + i] = c
	}
	// relocation_info: r_address, then a packed 32-bit word.
	for i, r in e.relocs {
		ro := off_reloc + i * 8
		macho_put32(mut b, ro, r.offset)
		mut packed := u32(r.sym & 0xffffff)
		packed |= u32(1) << 24 // r_pcrel
		packed |= u32(2) << 25 // r_length = 4 bytes
		packed |= u32(1) << 27 // r_extern
		packed |= u32(r.typ) << 28
		macho_put32(mut b, ro + 4, packed)
	}
	for i, s in e.symbols {
		so := off_syms + i * 16
		macho_put32(mut b, so, u32(name_off[s.name]))
		if s.is_undefined {
			b[so + 4] = n_undf | n_ext
			b[so + 5] = 0
		} else {
			b[so + 4] = n_sect | n_ext
			b[so + 5] = 1
		}
		macho_put16(mut b, so + 6, 0)
		macho_put64(mut b, so + 8, s.value)
	}
	for i, c in strtab {
		b[off_str + i] = c
	}

	os.write_file_array(path, b) or {
		return error('vir: writing MachO object `${path}` failed: ${err.msg()}')
	}
}
