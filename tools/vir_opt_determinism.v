module main

// M2 determinism proof: run `virc opt` repeatedly over every available IR
// source and require byte-identical output each time. Run:
//   v run tools/vir_opt_determinism.v [repetitions]

import os

fn main() {
	reps := 5
	root := @VMODROOT
	virc := os.join_path(root, 'virc.exe')
	out_dir := os.join_path(os.getenv('LOCALAPPDATA'), 'Temp', 'opencode', 'vir-opt-det')
	os.mkdir_all(out_dir)!

	mut sources := []string{}
	base := os.join_path(root, 'testdata')
	for f in os.ls(base)! {
		if f.ends_with('.vir') {
			sources << os.join_path(base, f)
		}
	}
	for dirname in ['cminus', 'vmini'] {
		dir := os.join_path(base, dirname)
		for f in os.ls(dir)! {
			if !f.ends_with('.c') && !f.ends_with('.v') {
				continue
			}
			src := os.join_path(dir, f)
			ir := os.join_path(out_dir, '${dirname}_${f}.vir')
			cmd := if f.ends_with('.c') { 'cminus' } else { 'vmini' }
			r := os.exec_opt([virc, cmd, src, ir]) or { continue }
			if r.exit_code == 0 {
				sources << ir
			}
		}
	}

	mut checked := 0
	mut failed := 0
	for src in sources {
		mut first := ''
		for i in 0 .. reps {
			r := os.exec_opt([virc, 'opt', src]) or {
				println('det: exec failed for ${src}')
				failed++
				break
			}
			if r.exit_code != 0 {
				println('det: opt failed for ${src}: ${r.output}')
				failed++
				break
			}
			if i == 0 {
				first = r.output
			} else if r.output != first {
				println('det: NON-DETERMINISTIC output for ${src}')
				failed++
				break
			}
		}
		checked++
	}
	if failed > 0 {
		println('det: ${failed} failures over ${checked} sources')
		exit(1)
	}
	println('det: ${checked} sources x ${reps} runs byte-identical')
}
