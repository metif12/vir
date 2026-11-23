module cminus

import os
import pipeline

fn rv_u16(b []u8, off int) u16 {
	return u16(b[off]) | (u16(b[off + 1]) << 8)
}

fn rv_u64(b []u8, off int) u64 {
	mut v := u64(0)
	for i in 0 .. 8 {
		v |= u64(b[off + i]) << (8 * i)
	}
	return v
}

fn rv_cstr(b []u8, off int) string {
	mut end := off
	for end < b.len && b[end] != 0 {
		end++
	}
	return b[off..end].bytestr()
}

fn rv_section(b []u8, want string) (int, int) {
	assert rv_u16(b, 60) == 13 // nine base sections plus four DWARF ones
	shoff := int(rv_u64(b, 40))
	shstr_hdr := shoff + 7 * 64
	shstr_off := int(rv_u64(b, shstr_hdr + 24))
	for i in 0 .. 13 {
		hdr := shoff + i * 64
		name := rv_cstr(b, shstr_off + int(rv_u32(b, hdr)))
		if name == want {
			return int(rv_u64(b, hdr + 24)), int(rv_u64(b, hdr + 32))
		}
	}
	assert false, 'section ${want} not found'
	return 0, 0
}

fn rv_u32(b []u8, off int) u32 {
	mut v := u32(0)
	for i in 0 .. 4 {
		v |= u32(b[off + i]) << (8 * i)
	}
	return v
}

// test_compile_debug_emits_loc_section locks in the location-list pipeline:
// frontend variable names must reach a non-empty .debug_loc section and
// named variable DIEs in .debug_info.
fn test_compile_debug_emits_loc_section() {
	src := os.read_file(os.join_path(@VMODROOT, 'testdata', 'cminus', 'while.c'))!
	funcs := parse(src)!
	mut mod, dbg := generate_with_debug(funcs)!
	assert dbg.vars.len > 0
	path := os.join_path(os.vtmp_dir(), 'vir_cminus_debug_${os.getpid()}.o')
	defer {
		os.rm(path) or {}
	}
	pipeline.compile_module_debug(mut mod, 'amd64-linux-gnu', path, dbg)!
	buf := os.read_bytes(path)!
	assert buf[0] == 0x7f
	assert buf[1] == 0x45 // ELF magic

	loc_off, loc_size := rv_section(buf, '.debug_loc')
	// At least two single-range register entries plus terminators.
	assert loc_size >= 2 * (18 + 16)
	// First entry is a valid range: begin < end.
	assert rv_u64(buf, loc_off) < rv_u64(buf, loc_off + 8)
	// Terminators exist: scan for a 16-zero run.
	mut found_term := false
	for i in 0 .. loc_size - 15 {
		mut all_zero := true
		for j in 0 .. 16 {
			if buf[loc_off + i + j] != 0 {
				all_zero = false
				break
			}
		}
		if all_zero {
			found_term = true
			break
		}
	}
	assert found_term

	info_off, _ := rv_section(buf, '.debug_info')
	info := buf[info_off..].bytestr()
	assert info.contains('sum')
	assert info.contains('i')
}
