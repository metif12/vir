module jit

import os
import cminus
import vmini
import pipeline
import target
import emit

fn run_c(src string) !int {
	funcs := cminus.parse(src)!
	mut m := cminus.generate(funcs)!
	t := target.parse_triple('amd64-windows-msvc')!
	out := pipeline.lower_module(mut m, t, map[int]int{})!
	return run(&out, 'main')!
}

fn run_v(src string) !int {
	funcs := vmini.parse(src)!
	mut m := cminus.generate(funcs)!
	t := target.parse_triple('amd64-windows-msvc')!
	out := pipeline.lower_module(mut m, t, map[int]int{})!
	return run(&out, 'main')!
}

fn fixture(dir string, name string) !string {
	return os.read_file(os.join_path(@VMODROOT, 'testdata', dir, name))!
}

fn test_jit_add() {
	assert run_c(fixture('cminus', 'add.c')!)! == 7
}

fn test_jit_locals() {
	assert run_c(fixture('cminus', 'locals.c')!)! == 8
}

fn test_jit_if() {
	assert run_c(fixture('cminus', 'if.c')!)! == 7
}

fn test_jit_while() {
	assert run_c(fixture('cminus', 'while.c')!)! == 10
}

fn test_jit_call() {
	// Cross-function PC32/PLT32 relocation through the JIT region.
	assert run_c(fixture('cminus', 'func.c')!)! == 10
}

fn test_jit_vmini_while() {
	assert run_v(fixture('vmini', 'while.v')!)! == 10
}

fn test_jit_rejects_externals() {
	out := pipeline.lower_module(mut cminus.generate(cminus.parse(fixture('cminus',
		'add.c')!)!)!, target.parse_triple('amd64-windows-msvc')!, map[int]int{})!
	mut bad := out
	bad.syms << emit.EmitSym{ name: 'puts', is_undefined: true }
	bad.relocs << emit.EmitReloc{ offset: 1, sym: bad.syms.len - 1, typ: emit.r_x86_64_plt32, addend: -4 }
	run(&bad, 'main') or {
		assert err.msg().contains('puts')
		return
	}
	assert false, 'expected external symbol to be rejected'
}

fn test_jit_missing_entry() {
	out := pipeline.lower_module(mut cminus.generate(cminus.parse(fixture('cminus',
		'add.c')!)!)!, target.parse_triple('amd64-windows-msvc')!, map[int]int{})!
	run(&out, 'nope') or {
		assert err.msg().contains('nope')
		return
	}
	assert false, 'expected missing entry to be rejected'
}
