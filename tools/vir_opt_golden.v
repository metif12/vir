module main

// Regenerate the M2 golden IR outputs. Run deliberately when an intended
// optimizer change requires updating the frozen baselines:
//   v run tools/vir_opt_golden.v

import os

fn main() {
	root := @VMODROOT
	virc := os.join_path(root, 'virc.exe')
	golden_dir := os.join_path(root, 'testdata', 'golden')
	tmp_dir := os.join_path(os.getenv('LOCALAPPDATA'), 'Temp', 'opencode', 'vir-opt-golden')
	os.mkdir_all(golden_dir)!
	os.mkdir_all(tmp_dir)!

	mut count := 0
	base := os.join_path(root, 'testdata')
	for f in os.ls(base)! {
		if f.ends_with('.vir') {
			r := os.exec_opt([virc, 'opt', os.join_path(base, f)])!
			os.write_file(os.join_path(golden_dir, f), r.output)!
			count++
		}
	}
	for dirname in ['cminus', 'vmini'] {
		dir := os.join_path(base, dirname)
		for f in os.ls(dir)! {
			if !f.ends_with('.c') && !f.ends_with('.v') {
				continue
			}
			src := os.join_path(dir, f)
			ir := os.join_path(tmp_dir, '${dirname}_${f}.vir')
			cmd := if f.ends_with('.c') { 'cminus' } else { 'vmini' }
			fr := os.exec_opt([virc, cmd, src, ir])!
			if fr.exit_code != 0 {
				continue
			}
			r := os.exec_opt([virc, 'opt', ir])!
			stem := f[..f.len - 2]
			os.write_file(os.join_path(golden_dir, '${dirname}_${stem}.vir'), r.output)!
			count++
		}
	}
	println('golden: wrote ${count} files to ${golden_dir}')
}
