module main

import os

// Minimal .vir module: a frameless function returning x + 1. Uses the same
// header shape as testdata/smoke.vir so the text parser is exercised too.
const add_src = 'vir 1\n' +
	'target os - arch - ptr 8 endian little\n' +
	'type %t0 = void\n' +
	'type %t1 = i32\n' +
	'const %v1 %t1 "1"\n' +
	'func 0 "main" -> %t1 linkage external callconv c_decl params (%v2 "x" : %t1)\n' +
	'@b0 "entry" :\n' +
	'  %v3 = add %t1, %v2, %v1\n' +
	'  %v4 = ret %t1, %v3\n' +
	'detached\n'

fn obj_path(name string) string {
	return os.join_path(os.vtmp_dir(), 'vir_compile_${os.getpid()}_${name}.o')
}

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

fn cstr_at(b []u8, off int) string {
	mut end := off
	for end < b.len && b[end] != 0 {
		end++
	}
	return b[off..end].bytestr()
}

fn section_off(b []u8, shoff int, idx int) int {
	return int(rd_u64(b, shoff + idx * 64 + 24))
}

fn section_size(b []u8, shoff int, idx int) int {
	return int(rd_u64(b, shoff + idx * 64 + 32))
}

fn test_compile_file_emits_elf_object() {
	path := obj_path('add')
	defer {
		os.rm(path) or {}
	}
	compile_file(add_src, 'amd64-linux-gnu', path)!
	buf := os.read_bytes(path)!
	assert buf[0] == 0x7f
	assert buf[1] == 0x45 // E
	assert buf[2] == 0x4c // L
	assert buf[3] == 0x46 // F
	assert rd_u16(buf, 16) == 1 // ET_REL
	assert rd_u16(buf, 18) == 62 // EM_X86_64
	assert rd_u16(buf, 60) == 9 // nine sections

	shoff := int(rd_u64(buf, 40))
	text_off := section_off(buf, shoff, 1)
	assert buf[text_off] == 0x55 // push rbp
	assert buf[text_off + 1] == 0x48
	assert buf[text_off + 2] == 0x89
	assert buf[text_off + 3] == 0xe5 // mov rbp, rsp

	// A defined global `main` lives in .text (section index 1).
	sym_off := section_off(buf, shoff, 4)
	sym_size := section_size(buf, shoff, 4)
	str_off := section_off(buf, shoff, 5)
	mut found := false
	for i := 0; i < sym_size / 24; i++ {
		ent := sym_off + i * 24
		if cstr_at(buf, str_off + int(rd_u32(buf, ent))) == 'main' {
			found = true
			assert buf[ent + 4] == 0x12 // STB_GLOBAL | STT_FUNC
			assert rd_u16(buf, ent + 6) == 1 // .text
		}
	}
	assert found
}

fn test_compile_file_smoke_corpus() {
	path := obj_path('smoke')
	defer {
		os.rm(path) or {}
	}
	src := os.read_file(os.join_path(@VMODROOT, 'testdata', 'smoke.vir'))!
	compile_file(src, 'amd64-linux-gnu', path)!
	buf := os.read_bytes(path)!
	assert buf[0] == 0x7f
	assert rd_u16(buf, 18) == 62
	shoff := int(rd_u64(buf, 40))
	assert buf[section_off(buf, shoff, 1)] == 0x55 // push rbp
}

fn test_compile_file_rejects_non_amd64() {
	path := obj_path('arm')
	defer {
		os.rm(path) or {}
	}
	compile_file(add_src, 'arm64-linux-gnu', path) or {
		assert err.msg().contains('amd64')
		return
	}
	assert false, 'expected a rejection for arm64'
}
