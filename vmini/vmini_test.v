module vmini

import os
import cminus
import vssa.ssa
import vssa.optimize
import pipeline

fn fixture(name string) !string {
	return os.read_file(os.join_path(@VMODROOT, 'testdata', 'vmini', '${name}.v'))!
}

fn compile_fixture(name string) !string {
	funcs := parse(fixture(name)!)!
	mut m := cminus.generate(funcs)!
	text := ssa.module_to_text(m)!
	mut m2 := ssa.module_from_text(text)!
	assert ssa.module_to_text(m2)! == text
	optimize.optimize(mut m2)
	assert optimize.verify(m2).len == 0, 'vmini ${name} failed verification'
	path := os.join_path(os.vtmp_dir(), 'vir_vmini_${os.getpid()}_${name}.o')
	defer {
		os.rm(path) or {}
	}
	pipeline.compile_module(mut m2, 'amd64-linux-gnu', path)!
	buf := os.read_bytes(path)!
	assert buf[0] == 0x7f
	assert buf[1] == 0x45
	return text
}

fn test_vmini_arithmetic() {
	text := compile_fixture('add')!
	assert text.contains('func 0 "main"')
	assert text.contains(' mul ')
	assert text.contains(' ret ')
}

fn test_vmini_locals() {
	text := compile_fixture('locals')!
	assert text.contains(' alloca ')
	assert text.contains(' sdiv ')
	assert text.contains(' srem ')
}

fn test_vmini_conditionals() {
	text := compile_fixture('if')!
	assert text.contains(' br ')
	assert text.contains(' eq ')
}

fn test_vmini_range_loop() {
	text := compile_fixture('while')!
	// `for i in 0 .. 5` lowers to a counter init plus a while loop.
	assert text.contains(' jmp ')
	assert text.contains(' lt ')
	assert text.contains(' add ')
}

fn test_vmini_calls() {
	text := compile_fixture('func')!
	assert text.contains(' call ')
	assert text.contains(' add ')
}
