module obj

import os

fn macho_rd32(b []u8, off int) u32 {
	return u32(b[off]) | (u32(b[off + 1]) << 8) | (u32(b[off + 2]) << 16) |
		(u32(b[off + 3]) << 24)
}

fn macho_rd64(b []u8, off int) u64 {
	mut v := u64(0)
	for i in 0 .. 8 {
		v |= u64(b[off + i]) << (8 * i)
	}
	return v
}

fn macho_fixed_name(b []u8, off int, n int) string {
	return b[off..off + n].bytestr().trim('\x00')
}

fn macho_path(name string) string {
	return os.join_path(os.vtmp_dir(), 'vir_macho_${os.getpid()}_${name}.o')
}

fn test_macho_header_and_section() {
	mut o := MachObject.new()
	o.text_data = [u8(0x55), 0x48, 0x89, 0xe5, 0xc3]
	path := macho_path('header')
	defer {
		os.rm(path) or {}
	}
	o.write(path)!
	b := os.read_bytes(path)!

	assert macho_rd32(b, 0) == 0xfeedfacf
	assert macho_rd32(b, 4) == cputype_x86_64
	assert macho_rd32(b, 8) == cpusubtype_x86_64_all
	assert macho_rd32(b, 12) == 1 // MH_OBJECT
	assert macho_rd32(b, 16) == 2 // two load commands

	seg := 32
	assert macho_rd32(b, seg) == 0x19 // LC_SEGMENT_64
	assert macho_fixed_name(b, seg + 8, 16) == '__TEXT'
	sec := seg + 72
	assert macho_fixed_name(b, sec, 16) == '__text'
	assert macho_fixed_name(b, sec + 16, 16) == '__TEXT'
	assert macho_rd64(b, sec + 40) == u64(o.text_data.len)
	text_off := int(macho_rd32(b, sec + 48))
	assert b[text_off..text_off + o.text_data.len] == o.text_data
}

fn test_macho_symbols_and_relocs() {
	mut o := MachObject.new()
	o.text_data = [u8(0xe8), 0, 0, 0, 0, 0xc3]
	main_idx := o.add_symbol('main', 0, true)
	puts_idx := o.add_undefined('puts')
	o.add_text_reloc(1, puts_idx, 4) // PLT32 -> branch
	assert main_idx == 0
	assert puts_idx == 1

	path := macho_path('symbols')
	defer {
		os.rm(path) or {}
	}
	o.write(path)!
	b := os.read_bytes(path)!
	symcmd := 32 + 152
	assert macho_rd32(b, symcmd) == 0x2 // LC_SYMTAB
	sym_off := int(macho_rd32(b, symcmd + 8))
	str_off := int(macho_rd32(b, symcmd + 16))
	assert macho_rd32(b, symcmd + 12) == 2

	main_ent := sym_off + main_idx * 16
	assert b[str_off + int(macho_rd32(b, main_ent))] == `m`
	assert b[main_ent + 4] == 0x0f // N_SECT | N_EXT
	assert b[main_ent + 5] == 1
	assert macho_rd64(b, main_ent + 8) == 0

	puts_ent := sym_off + puts_idx * 16
	assert b[str_off + int(macho_rd32(b, puts_ent))] == `p`
	assert b[puts_ent + 4] == 0x01 // N_UNDF | N_EXT

	sec := 32 + 72
	reloc_off := int(macho_rd32(b, sec + 56))
	assert macho_rd32(b, sec + 60) == 1
	assert macho_rd32(b, reloc_off) == 1
	packed := macho_rd32(b, reloc_off + 4)
	assert packed & 0x00ffffff == u32(puts_idx)
	assert (packed >> 24) & 1 == 1 // pcrel
	assert (packed >> 25) & 3 == 2 // 4-byte field
	assert (packed >> 27) & 1 == 1 // external
	assert (packed >> 28) & 0xf == 2 // X86_64_RELOC_BRANCH
	assert str_off > sym_off
}

fn test_macho_write_failure_returns_error() {
	mut o := MachObject.new()
	missing := os.join_path(os.vtmp_dir(), 'vir_macho_no_such_dir', 'fail.o')
	o.write(missing) or {
		assert err.msg().contains('vir:')
		return
	}
	assert false, 'expected an error writing into a missing directory'
}
