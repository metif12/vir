module libvir

import os

// Same minimal module used by compile_test.v, expressed as a C string source.
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

fn last_error_text() string {
	return unsafe { c_last_error().vstring() }
}

fn test_abi_version() {
	assert c_abi_version() == abi_version
}

fn test_c_pipeline_emits_elf() {
	h := c_parse(add_src.str)
	assert !isnil(h)
	assert c_optimize(h) == 0
	assert c_verify(h) == 0

	path := os.join_path(os.vtmp_dir(), 'vir_libvir_${os.getpid()}.o')
	defer {
		os.rm(path) or {}
	}
	assert c_compile(h, c'amd64-linux-gnu', path.str) == 0
	assert last_error_text() == ''

	buf := os.read_bytes(path)!
	assert buf[0] == 0x7f
	assert buf[1] == 0x45
	assert buf[2] == 0x4c
	assert buf[3] == 0x46
	assert buf[18] == 62 // EM_X86_64
	c_module_free(h)

	// A freed handle is no longer usable.
	assert c_verify(h) == 1
	assert last_error_text().contains('invalid module handle')
}

fn test_c_parse_reports_error() {
	h := c_parse(c'this is not vir text')
	assert isnil(h)
	assert last_error_text().len > 0
}

fn test_c_compile_rejects_non_amd64() {
	h := c_parse(add_src.str)
	assert !isnil(h)
	path := os.join_path(os.vtmp_dir(), 'vir_libvir_arm_${os.getpid()}.o')
	defer {
		os.rm(path) or {}
	}
	assert c_compile(h, c'arm64-linux-gnu', path.str) == 1
	assert last_error_text().contains('amd64')
	c_module_free(h)
}
