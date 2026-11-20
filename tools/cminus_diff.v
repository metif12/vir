module main

// Differential harness for M6: for each C-minus fixture, compile it with vir
// (frontend -> .vir -> ELF object), link and run the object with Linux gcc in
// WSL, then compile and run the same C source with gcc directly. The two exit
// codes must match. Run with: v run tools/cminus_diff.v

import os

const wsl_tmp = '/tmp/vir_m6_diff'

fn win_to_wsl(p string) string {
	s := p.replace('\\', '/')
	if s.len > 1 && s[1] == `:` {
		return '/mnt/${s[0..1].to_lower()}${s[2..]}'
	}
	return s
}

fn run(cmd []string) !os.Result {
	r := os.exec_opt(cmd) or {
		return error('exec ${cmd[0]} failed: ${err.msg()}')
	}
	return r
}

fn exit_of(out string) int {
	lines := out.split_into_lines()
	for i := lines.len - 1; i >= 0; i-- {
		line := lines[i].trim(' \t\r\n')
		if line.starts_with('EXIT=') {
			return line[5..].int()
		}
	}
	return -999
}

fn main() {
	root := @VMODROOT
	virc := os.join_path(root, 'virc.exe')
	src_dir := os.join_path(root, 'testdata', 'cminus')
	out_dir := os.join_path(os.getenv('LOCALAPPDATA'), 'Temp', 'opencode', 'vir-m6-diff')
	os.mkdir_all(out_dir)!

	init := run(['wsl', '-e', 'sh', '-lc', 'mkdir -p ${wsl_tmp}'])!
	if init.exit_code != 0 {
		eprintln('cminus_diff: cannot create ${wsl_tmp}: ${init.output}')
		exit(1)
	}

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
		obj := os.join_path(out_dir, '${name}.o')

		r1 := run([virc, 'cminus', src, ir])!
		if r1.exit_code != 0 {
			eprintln('cminus_diff: ${name}: frontend failed: ${r1.output}')
			failed++
			continue
		}
		r2 := run([virc, 'compile', ir, obj])!
		if r2.exit_code != 0 {
			eprintln('cminus_diff: ${name}: object emission failed: ${r2.output}')
			failed++
			continue
		}

		vcmd := 'gcc ${win_to_wsl(obj)} -o ${wsl_tmp}/${name}_v && ${wsl_tmp}/${name}_v; echo EXIT=$?'
		rv := run(['wsl', '-e', 'sh', '-lc', vcmd])!
		vcode := exit_of(rv.output)

		gcmd := 'gcc ${win_to_wsl(src)} -o ${wsl_tmp}/${name}_g && ${wsl_tmp}/${name}_g; echo EXIT=$?'
		rg := run(['wsl', '-e', 'sh', '-lc', gcmd])!
		gcode := exit_of(rg.output)

		if vcode != gcode {
			eprintln('cminus_diff: ${name}: MISMATCH vir=${vcode} gcc=${gcode}')
			eprintln('  vir output: ${rv.output.trim(' \t\r\n')}')
			eprintln('  gcc output: ${rg.output.trim(' \t\r\n')}')
			failed++
		} else {
			println('cminus_diff: ${name}: OK (exit ${vcode})')
		}
	}
	if failed > 0 {
		eprintln('cminus_diff: ${failed}/${total} failed')
		exit(1)
	}
	println('cminus_diff: ${total}/${total} matched gcc')
}
