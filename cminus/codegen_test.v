module cminus

import os
import vssa.ssa
import vssa.optimize
import pipeline

fn fixture(name string) !string {
	return os.read_file(os.join_path(@VMODROOT, 'testdata', 'cminus', name))!
}

fn build_object(src string, path string) !string {
	funcs := parse(src)!
	mut m := generate(funcs)!
	text := ssa.module_to_text(m)!
	// Round-trip the generated IR through the text format before lowering.
	mut m2 := ssa.module_from_text(text)!
	assert ssa.module_to_text(m2)! == text
	optimize.optimize(mut m2)
	assert optimize.verify(m2).len == 0, 'generated module failed verification'
	pipeline.compile_module(mut m2, 'amd64-linux-gnu', path)!
	return text
}

fn obj_path(name string) string {
	return os.join_path(os.vtmp_dir(), 'vir_cminus_${os.getpid()}_${name}.o')
}

fn test_codegen_generates_verifiable_ir() {
	text := build_object(fixture('add.c')!, obj_path('add'))!
	assert text.contains('func 0 "main"')
	assert text.contains(' ret ')
	assert text.contains(' mul ')
}

fn test_codegen_locals() {
	text := build_object(fixture('locals.c')!, obj_path('locals'))!
	assert text.contains(' alloca ')
	assert text.contains(' store ')
	assert text.contains(' load ')
	assert text.contains(' sdiv ')
	assert text.contains(' srem ')
}

fn test_codegen_control_flow() {
	text := build_object(fixture('if.c')!, obj_path('if'))!
	assert text.contains(' br ')
	assert text.contains(' gt ')
	assert text.contains(' eq ')
	buf := os.read_bytes(obj_path('if'))!
	assert buf[0] == 0x7f
	assert buf[1] == 0x45
}

fn test_codegen_loop() {
	text := build_object(fixture('while.c')!, obj_path('while'))!
	assert text.contains(' jmp ')
	assert text.contains(' lt ')
}

fn test_codegen_calls() {
	text := build_object(fixture('func.c')!, obj_path('func'))!
	assert text.contains(' call ')
	assert text.contains(' add ')
}
