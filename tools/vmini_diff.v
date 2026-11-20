module main

// V dogfood differential: compile each V-subset fixture with vir (frontend ->
// .vir -> COFF object -> native exe) and with the stock V compiler, then
// compare the two exit codes. Run: v run tools/vmini_diff.v

import os

fn main() {
	root := @VMODROOT
	virc := os.join_path(root, 'virc.exe')
	mut vcomp := os.getenv('VIRC_V')
	if vcomp == '' {
		vcomp = 'C:\\Users\\MR\\v-0.5.2-release\\v.exe'
	}
	src_dir := os.join_path(root, 'testdata', 'vmini')
	out_dir := os.join_path(os.getenv('LOCALAPPDATA'), 'Temp', 'opencode', 'vir-vmini-diff')
	os.mkdir_all(out_dir)!
	os.setenv('VJOBS', '1', true)

	files := os.ls(src_dir)!
	mut total := 0
	mut failed := 0
	for file in files {
		if !file.ends_with('.v') {
			continue
		}
		total++
		name := file[..file.len - 2]
		src := os.join_path(src_dir, file)
		ir := os.join_path(out_dir, '${name}.vir')
		obj := os.join_path(out_dir, '${name}.obj')
		vexe := os.join_path(out_dir, '${name}_vir.exe')
		refexe := os.join_path(out_dir, '${name}_v.exe')

		r1 := os.exec_opt([virc, 'vmini', src, ir]) or {
			println('vmini_diff: ${name}: frontend spawn failed')
			failed++
			continue
		}
		r2 := os.exec_opt([virc, 'compile', ir, obj, 'amd64-windows-msvc']) or {
			println('vmini_diff: ${name}: object emission failed')
			failed++
			continue
		}
		if r1.exit_code != 0 || r2.exit_code != 0 {
			println('vmini_diff: ${name}: vir failed: ${r1.output} ${r2.output}')
			failed++
			continue
		}
		lr := os.exec_opt(['gcc', obj, '-o', vexe]) or {
			println('vmini_diff: ${name}: link failed')
			failed++
			continue
		}
		if lr.exit_code != 0 {
			println('vmini_diff: ${name}: link failed: ${lr.output}')
			failed++
			continue
		}
		cr := os.exec_opt([vcomp, '-o', refexe, src]) or {
			println('vmini_diff: ${name}: V compile failed')
			failed++
			continue
		}
		if cr.exit_code != 0 {
			println('vmini_diff: ${name}: V compile failed: ${cr.output}')
			failed++
			continue
		}

		rv := os.exec([vexe])
		rg := os.exec([refexe])
		if rv.exit_code != rg.exit_code {
			println('vmini_diff: ${name}: MISMATCH vir=${rv.exit_code} v=${rg.exit_code}')
			failed++
		} else {
			println('vmini_diff: ${name}: OK (exit ${rv.exit_code})')
		}
	}
	if failed > 0 {
		println('vmini_diff: ${failed}/${total} failed')
		exit(1)
	}
	println('vmini_diff: ${total}/${total} matched the V compiler')
}
