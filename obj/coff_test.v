module obj

import os

fn coff_rd_u16(b []u8, off int) u16 {
	return u16(b[off]) | (u16(b[off + 1]) << 8)
}

fn coff_rd_u32(b []u8, off int) u32 {
	mut v := u32(0)
	for i in 0 .. 4 {
		v |= u32(b[off + i]) << (8 * i)
	}
	return v
}

fn coff_name_at(b []u8, off int, len int) string {
	return b[off..off + len].bytestr().trim('\x00')
}

fn coff_path(name string) string {
	return os.join_path(os.vtmp_dir(), 'vir_coff_${os.getpid()}_${name}.obj')
}

fn test_coff_header_and_sections() {
	mut e := CoffObject.new(image_file_machine_amd64)
	e.text_data = [u8(0x55), 0x48, 0x89, 0xe5, 0xc3]
	path := coff_path('header')
	defer {
		os.rm(path) or {}
	}
	e.write(path)!
	b := os.read_bytes(path)!

	assert coff_rd_u16(b, 0) == 0x8664
	assert coff_rd_u16(b, 2) == 2 // .text and .data
	sym_off := int(coff_rd_u32(b, 8))
	assert coff_rd_u32(b, 12) == 0 // no symbols yet

	sh1 := 20
	assert coff_name_at(b, sh1, 8) == '.text'
	assert coff_rd_u32(b, sh1 + 16) == u32(e.text_data.len)
	text_off := int(coff_rd_u32(b, sh1 + 20))
	assert b[text_off..text_off + e.text_data.len] == e.text_data

	sh2 := 20 + 40
	assert coff_name_at(b, sh2, 8) == '.data'
	assert sym_off > text_off + e.text_data.len
}

fn test_coff_symbols_and_relocs() {
	mut e := CoffObject.new(image_file_machine_amd64)
	e.text_data = [u8(0xe8), 0xff, 0xff, 0xff, 0xff, 0xc3]
	main_idx := e.add_symbol('main', 0, true, 1)
	puts_idx := e.add_undefined('puts')
	e.add_text_reloc(1, puts_idx, image_rel_amd64_rel32)
	assert main_idx == 0
	assert puts_idx == 1

	path := coff_path('symbols')
	defer {
		os.rm(path) or {}
	}
	e.write(path)!
	b := os.read_bytes(path)!
	sym_off := int(coff_rd_u32(b, 8))
	assert coff_rd_u32(b, 12) == 2

	main_ent := sym_off + main_idx * 18
	assert coff_name_at(b, main_ent, 8) == 'main'
	assert coff_rd_u32(b, main_ent + 8) == 0
	assert coff_rd_u16(b, main_ent + 12) == 1 // .text
	assert coff_rd_u16(b, main_ent + 14) == 0x20 // function
	assert b[main_ent + 16] == 2 // external

	puts_ent := sym_off + puts_idx * 18
	assert coff_name_at(b, puts_ent, 8) == 'puts'
	assert coff_rd_u16(b, puts_ent + 12) == 0 // undefined

	sh1 := 20
	assert coff_rd_u16(b, sh1 + 32) == 1 // one relocation
	reloc_off := int(coff_rd_u32(b, sh1 + 24))
	assert coff_rd_u32(b, reloc_off) == 1
	assert coff_rd_u32(b, reloc_off + 4) == u32(puts_idx)
	assert coff_rd_u16(b, reloc_off + 8) == image_rel_amd64_rel32
}

fn test_coff_long_symbol_name() {
	mut e := CoffObject.new(image_file_machine_amd64)
	long_name := 'a_very_long_function_name'
	idx := e.add_symbol(long_name, 4, true, 1)
	assert idx == 0
	path := coff_path('long')
	defer {
		os.rm(path) or {}
	}
	e.write(path)!
	b := os.read_bytes(path)!
	sym_off := int(coff_rd_u32(b, 8))
	assert coff_rd_u32(b, sym_off) == 0 // inline name empty
	str_off := sym_off + 18
	name_off := int(coff_rd_u32(b, sym_off + 4))
	assert b[str_off + name_off..str_off + name_off + long_name.len].bytestr() == long_name
}

fn test_coff_write_failure_returns_error() {
	mut e := CoffObject.new(image_file_machine_amd64)
	missing := os.join_path(os.vtmp_dir(), 'vir_coff_no_such_dir', 'fail.obj')
	e.write(missing) or {
		assert err.msg().contains('vir:')
		return
	}
	assert false, 'expected an error writing into a missing directory'
}
