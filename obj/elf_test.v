module obj

import os

// Test helpers: little-endian readers over the serialized object bytes.

fn rd_u16(b []u8, off int) u16 {
	return u16(b[off]) | (u16(b[off + 1]) << 8)
}

fn rd_u32(b []u8, off int) u32 {
	mut v := u32(0)
	for i in 0 .. 4 {
		v |= u32(b[off + i]) << (8 * i)
	}
	return v
}

fn rd_u64(b []u8, off int) u64 {
	mut v := u64(0)
	for i in 0 .. 8 {
		v |= u64(b[off + i]) << (8 * i)
	}
	return v
}

// cstr_at reads the NUL-terminated string starting at off in b.
fn cstr_at(b []u8, off int) string {
	mut end := off
	for end < b.len && b[end] != 0 {
		end++
	}
	return b[off..end].bytestr()
}

fn tmp_obj_path(name string) string {
	return os.join_path(os.vtmp_dir(), 'vir_obj_${os.getpid()}_${name}.o')
}

fn test_elf_header_layout() {
	mut e := ElfObject.new(em_x86_64)
	e.text_data = [u8(0x90), 0x90, 0xc3] // nop; nop; ret
	path := tmp_obj_path('header')
	defer {
		os.rm(path) or {}
	}
	e.write(path)!
	buf := os.read_bytes(path)!
	// ELF identification
	assert buf[0] == 0x7f
	assert buf[1] == 0x45 // 'E'
	assert buf[2] == 0x4c // 'L'
	assert buf[3] == 0x46 // 'F'
	assert buf[4] == 2 // ELFCLASS64
	assert buf[5] == 1 // ELFDATA2LSB
	assert buf[6] == 1 // EV_CURRENT
	// Header fields
	assert rd_u16(buf, 16) == 1 // e_type = ET_REL
	assert rd_u16(buf, 18) == em_x86_64 // e_machine
	assert rd_u32(buf, 20) == 1 // e_version
	assert rd_u16(buf, 52) == 64 // e_ehsize
	assert rd_u16(buf, 58) == 64 // e_shentsize
	assert rd_u16(buf, 60) == 9 // e_shnum
	assert rd_u16(buf, 62) == 7 // e_shstrndx
	shoff := rd_u64(buf, 40)
	assert shoff % 8 == 0
	assert buf.len == int(shoff) + 9 * 64
}

fn test_machine_roundtrip() {
	// The writer is machine-agnostic: any u16 must round-trip, not just 62.
	mut e := ElfObject.new(u16(183)) // EM_AARCH64
	path := tmp_obj_path('machine')
	defer {
		os.rm(path) or {}
	}
	e.write(path)!
	buf := os.read_bytes(path)!
	assert rd_u16(buf, 18) == 183
}

fn test_symbol_table_entries() {
	mut e := ElfObject.new(em_x86_64)
	assert e.symbols.len == 1 // null symbol comes first
	assert e.symbols[0].name == ''
	assert e.symbols[0].info == 0
	assert e.symbols[0].shndx == 0

	main_idx := e.add_symbol('main', 0, true, 1)
	msg_idx := e.add_symbol('msg', 8, false, 3)
	puts_idx := e.add_undefined('puts')
	assert main_idx == 1
	assert msg_idx == 2
	assert puts_idx == 3
	assert e.symbols.len == 4

	assert e.symbols[main_idx].name == 'main'
	assert e.symbols[main_idx].info == 0x12 // STB_GLOBAL | STT_FUNC
	assert e.symbols[main_idx].shndx == 1
	assert e.symbols[msg_idx].info == 0x11 // STB_GLOBAL | STT_OBJECT
	assert e.symbols[msg_idx].value == 8
	assert e.symbols[puts_idx].info == 0x10 // STB_GLOBAL | STT_NOTYPE
	assert e.symbols[puts_idx].shndx == 0 // undefined
	assert e.symbol_by_name['main'] == main_idx
	assert e.symbol_by_name['puts'] == puts_idx

	// Re-adding upgrades in place and keeps the index stable.
	assert e.add_symbol('main', 16, true, 1) == main_idx
	assert e.add_undefined('puts') == puts_idx
	assert e.symbols.len == 4
	assert e.symbols[main_idx].value == 16
}

fn test_text_reloc_entries() {
	mut e := ElfObject.new(em_x86_64)
	puts_idx := e.add_undefined('puts')
	e.add_text_reloc(4, puts_idx, 4, -4) // R_X86_64_PLT32, caller-supplied type
	e.add_text_reloc(10, puts_idx, 2, 0) // R_X86_64_PC32
	assert e.text_relocs.len == 2
	assert e.text_relocs[0].offset == 4
	assert e.text_relocs[0].info == (u64(puts_idx) << 32) | u64(4)
	assert e.text_relocs[0].addend == -4
	assert e.text_relocs[1].offset == 10
	assert e.text_relocs[1].info == (u64(puts_idx) << 32) | u64(2)
	assert e.text_relocs[1].addend == 0
}

fn test_serialized_sections_roundtrip() {
	mut e := ElfObject.new(em_x86_64)
	e.text_data = [u8(0x48), 0x89, 0xe5, 0xc3]
	e.data_data = [u8(1), 2, 3, 4, 5, 6, 7, 8]
	e.rodata_data = 'hi\0'.bytes()
	main_idx := e.add_symbol('main', 0, true, 1)
	msg_idx := e.add_symbol('msg', 0, false, 3)
	puts_idx := e.add_undefined('puts')
	e.add_text_reloc(1, puts_idx, 4, -4)
	path := tmp_obj_path('sections')
	defer {
		os.rm(path) or {}
	}
	e.write(path)!
	buf := os.read_bytes(path)!
	shoff := int(rd_u64(buf, 40))

	// .text (section 1)
	text_hdr := shoff + 1 * 64
	assert rd_u32(buf, text_hdr + 4) == 1 // SHT_PROGBITS
	assert rd_u64(buf, text_hdr + 8) == 0x6 // SHF_ALLOC | SHF_EXECINSTR
	text_off := int(rd_u64(buf, text_hdr + 24))
	assert text_off % 16 == 0
	assert rd_u64(buf, text_hdr + 32) == u64(e.text_data.len)
	assert buf[text_off..text_off + 4] == e.text_data

	// .data (section 2)
	data_hdr := shoff + 2 * 64
	assert rd_u64(buf, data_hdr + 8) == 0x3 // SHF_ALLOC | SHF_WRITE
	data_off := int(rd_u64(buf, data_hdr + 24))
	assert data_off % 8 == 0
	assert buf[data_off..data_off + 8] == e.data_data

	// .rodata (section 3)
	rodata_hdr := shoff + 3 * 64
	assert rd_u64(buf, rodata_hdr + 8) == 0x2 // SHF_ALLOC
	rodata_off := int(rd_u64(buf, rodata_hdr + 24))
	assert rd_u64(buf, rodata_hdr + 32) == u64(e.rodata_data.len)
	assert buf[rodata_off..rodata_off + 3] == e.rodata_data

	// .symtab (section 4), entries of 24 bytes
	sym_hdr := shoff + 4 * 64
	assert rd_u32(buf, sym_hdr + 4) == 2 // SHT_SYMTAB
	assert rd_u32(buf, sym_hdr + 40) == 5 // sh_link -> .strtab
	assert rd_u32(buf, sym_hdr + 44) == 1 // sh_info -> first global symbol
	assert rd_u64(buf, sym_hdr + 56) == 24 // sh_entsize
	sym_off := int(rd_u64(buf, sym_hdr + 24))
	assert sym_off % 8 == 0
	assert rd_u64(buf, sym_hdr + 32) == u64(e.symbols.len * 24)

	// .strtab (section 5) holds the symbol names.
	str_hdr := shoff + 5 * 64
	str_off := int(rd_u64(buf, str_hdr + 24))
	assert buf[str_off] == 0 // leading NUL
	main_ent := sym_off + main_idx * 24
	assert cstr_at(buf, str_off + int(rd_u32(buf, main_ent))) == 'main'
	assert buf[main_ent + 4] == 0x12 // st_info
	assert rd_u16(buf, main_ent + 6) == 1 // st_shndx
	assert rd_u64(buf, main_ent + 8) == 0 // st_value
	msg_ent := sym_off + msg_idx * 24
	assert cstr_at(buf, str_off + int(rd_u32(buf, msg_ent))) == 'msg'
	assert buf[msg_ent + 4] == 0x11
	puts_ent := sym_off + puts_idx * 24
	assert cstr_at(buf, str_off + int(rd_u32(buf, puts_ent))) == 'puts'
	assert buf[puts_ent + 4] == 0x10
	assert rd_u16(buf, puts_ent + 6) == 0 // SHN_UNDEF

	// .rela.text (section 6), entries of 24 bytes
	rela_hdr := shoff + 6 * 64
	assert rd_u32(buf, rela_hdr + 4) == 4 // SHT_RELA
	assert rd_u32(buf, rela_hdr + 40) == 4 // sh_link -> .symtab
	assert rd_u32(buf, rela_hdr + 44) == 1 // sh_info -> .text
	assert rd_u64(buf, rela_hdr + 56) == 24 // sh_entsize
	rela_off := int(rd_u64(buf, rela_hdr + 24))
	assert rela_off % 8 == 0
	assert rd_u64(buf, rela_hdr + 32) == 24 // one relocation
	assert rd_u64(buf, rela_off) == 1 // r_offset
	assert rd_u64(buf, rela_off + 8) == (u64(puts_idx) << 32) | u64(4)
	assert rd_u64(buf, rela_off + 16) == u64(0xfffffffffffffffc) // r_addend = -4

	// .shstrtab (section 7) names every section; e_shstrndx points at it.
	shstr_hdr := shoff + 7 * 64
	assert rd_u32(buf, shstr_hdr + 4) == 3 // SHT_STRTAB
	shstr_off := int(rd_u64(buf, shstr_hdr + 24))
	assert cstr_at(buf, shstr_off + int(rd_u32(buf, text_hdr))) == '.text'
	assert cstr_at(buf, shstr_off + int(rd_u32(buf, sym_hdr))) == '.symtab'
	assert cstr_at(buf, shstr_off + int(rd_u32(buf, rela_hdr))) == '.rela.text'
	assert cstr_at(buf, shstr_off + int(rd_u32(buf, shstr_hdr))) == '.shstrtab'

	// .note.GNU-stack (section 8): empty PROGBITS, no flags.
	stack_hdr := shoff + 8 * 64
	assert rd_u32(buf, stack_hdr + 4) == 1 // SHT_PROGBITS
	assert rd_u64(buf, stack_hdr + 8) == 0
	assert rd_u64(buf, stack_hdr + 24) == 0
	assert rd_u64(buf, stack_hdr + 32) == 0
	assert cstr_at(buf, shstr_off + int(rd_u32(buf, stack_hdr))) == '.note.GNU-stack'
}

fn test_elf_with_debug_sections() {
	mut e := ElfObject.new(em_x86_64)
	e.text_data = [u8(0x90), 0xc3]
	e.debug_info = [u8(1), 2, 3, 0]
	e.debug_abbrev = [u8(4), 5, 6, 0]
	e.debug_line = [u8(7), 8, 0]
	e.debug_loc = [u8(9), 0]
	path := tmp_obj_path('debug')
	defer {
		os.rm(path) or {}
	}
	e.write(path)!
	buf := os.read_bytes(path)!

	assert rd_u16(buf, 60) == 13 // nine base sections plus four DWARF ones
	shoff := int(rd_u64(buf, 40))
	shstr_hdr := shoff + 7 * 64
	shstr_off := int(rd_u64(buf, shstr_hdr + 24))

	info_hdr := shoff + 9 * 64
	assert cstr_at(buf, shstr_off + int(rd_u32(buf, info_hdr))) == '.debug_info'
	assert rd_u64(buf, info_hdr + 32) == 4
	info_off := int(rd_u64(buf, info_hdr + 24))
	assert buf[info_off..info_off + 4] == e.debug_info

	abbrev_hdr := shoff + 10 * 64
	assert cstr_at(buf, shstr_off + int(rd_u32(buf, abbrev_hdr))) == '.debug_abbrev'
	abbrev_off := int(rd_u64(buf, abbrev_hdr + 24))
	assert buf[abbrev_off..abbrev_off + 4] == e.debug_abbrev

	line_hdr := shoff + 11 * 64
	assert cstr_at(buf, shstr_off + int(rd_u32(buf, line_hdr))) == '.debug_line'
	line_off := int(rd_u64(buf, line_hdr + 24))
	assert buf[line_off..line_off + 3] == e.debug_line

	loc_hdr := shoff + 12 * 64
	assert cstr_at(buf, shstr_off + int(rd_u32(buf, loc_hdr))) == '.debug_loc'
	loc_off := int(rd_u64(buf, loc_hdr + 24))
	assert buf[loc_off..loc_off + 2] == e.debug_loc
}

fn test_write_failure_returns_error() {
	mut e := ElfObject.new(em_x86_64)
	missing := os.join_path(os.vtmp_dir(), 'vir_obj_no_such_dir', 'fail.o')
	e.write(missing) or {
		assert err.msg().contains('vir:')
		return
	}
	assert false, 'expected an error writing into a missing directory'
}
