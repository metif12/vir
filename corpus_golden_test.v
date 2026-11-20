module main

// M2 golden tests: the vendored pass manager's optimized output is frozen in
// testdata/golden/. Regenerate deliberately with tools/vir_opt_golden.v.

import os
import cminus
import vmini
import vssa.ssa
import vssa.optimize

fn golden_path(name string) string {
	return os.join_path(@VMODROOT, 'testdata', 'golden', '${name}.vir')
}

fn check_golden(name string, mut m &ssa.Module) ! {
	text := ssa.module_to_text(m)!
	mut parsed := ssa.module_from_text(text)!
	optimize.optimize(mut parsed)
	got := ssa.module_to_text(parsed)!
	want := os.read_file(golden_path(name))!
	assert got == want, 'golden mismatch for ${name}'
}

fn test_golden_smoke() {
	src := os.read_file(os.join_path(@VMODROOT, 'testdata', 'smoke.vir'))!
	mut m := ssa.module_from_text(src)!
	check_golden('smoke', mut m)
}

fn test_golden_cminus() {
	names := ['add', 'func', 'if', 'locals', 'regress_1', 'regress_2', 'regress_3', 'regress_4',
		'while']
	for name in names {
		src := os.read_file(os.join_path(@VMODROOT, 'testdata', 'cminus', '${name}.c'))!
		funcs := cminus.parse(src)!
		mut m := cminus.generate(funcs)!
		check_golden('cminus_${name}', mut m)
	}
}

fn test_golden_vmini() {
	names := ['add', 'func', 'if', 'locals', 'while']
	for name in names {
		src := os.read_file(os.join_path(@VMODROOT, 'testdata', 'vmini', '${name}.v'))!
		funcs := vmini.parse(src)!
		mut m := cminus.generate(funcs)!
		check_golden('vmini_${name}', mut m)
	}
}
