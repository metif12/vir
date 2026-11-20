module main

// Windows differential harness for the COFF object writer: compile each
// C-minus fixture to a COFF object, link it with MinGW gcc into a native .exe,
// and compare its exit code with gcc compiling the same source directly.
//
// Run: v run tools/coff_diff.v

import os

fn main() {
	root := @VMODROOT
	virc := os.join_path(root, 'virc.exe')
	src_dir := os.join_path(root, 'testdata', 'cminus')
	out_dir := os.join_path(os.getenv('LOCALAPPDATA'), 'Temp', 'opencode', 'vir-coff-diff')
	os.mkdir_all(out_dir)!

	// MinGW gcc is on PATH for this project; resolve it explicitly.
	gcc_exe := 'gcc'

	files := os.ls(src_dir)!
	mut total := 0
	mut failed := 0
	for file in files {
		if !file.ends_with('.c') {
			continue
		}
		total++
		name := file[..file.len - 2]
		src := os.join_path(src_dir, file)
		ir := os.join_path(out_dir, '${name}.vir')
		obj := os.join_path(out_dir, '${name}.obj')
		vexe := os.join_path(out_dir, '${name}_v.exe')
		gexe := os.join_path(out_dir, '${name}_g.exe')

		r1 := os.exec_opt([virc, 'cminus', src, ir]) or {
			println('coff_diff: ${name}: frontend failed')
			failed++
			continue
		}
		r2 := os.exec_opt([virc, 'compile', ir, obj, 'amd64-windows-msvc']) or {
			println('coff_diff: ${name}: COFF emission failed')
			failed++
			continue
		}
		if r1.exit_code != 0 || r2.exit_code != 0 {
			println('coff_diff: ${name}: vir failed: ${r1.output} ${r2.output}')
			failed++
			continue
		}
		lr := os.exec_opt([gcc_exe, obj, '-o', vexe]) or {
			println('coff_diff: ${name}: link failed')
			failed++
			continue
		}
		if lr.exit_code != 0 {
			println('coff_diff: ${name}: link failed: ${lr.output}')
			failed++
			continue
		}
		gr := os.exec_opt([gcc_exe, src, '-o', gexe]) or {
			println('coff_diff: ${name}: gcc compile failed')
			failed++
			continue
		}
		if gr.exit_code != 0 {
			println('coff_diff: ${name}: gcc compile failed: ${gr.output}')
			failed++
			continue
		}

		// os.exec (not exec_opt) keeps a non-zero exit code as a Result.
		rv := os.exec([vexe])
		rg := os.exec([gexe])
		if rv.exit_code != rg.exit_code {
			println('coff_diff: ${name}: MISMATCH vir=${rv.exit_code} gcc=${rg.exit_code}')
			failed++
		} else {
			println('coff_diff: ${name}: OK (exit ${rv.exit_code})')
		}
	}
	if failed > 0 {
		println('coff_diff: ${failed}/${total} failed')
		exit(1)
	}
	println('coff_diff: ${total}/${total} matched gcc')
}
