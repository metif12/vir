module main

// Differential harness for riscv64: for each C-minus fixture, compile it with
// vir (frontend -> .vir -> riscv64 ELF object), statically link it with the
// cross gcc in WSL, run it under qemu-riscv64, then compile and run the same
// C source with the cross gcc directly. The two exit codes must match.
// Requires virc.exe built and qemu-riscv64 + riscv64-linux-gnu-gcc in WSL.
// Run with: v run tools/riscv_diff.v

import os

const wsl_tmp = '/tmp/vir_rv_diff'

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
	out_dir := os.join_path(os.getenv('LOCALAPPDATA'), 'Temp', 'opencode', 'vir-rv-diff')
	os.mkdir_all(out_dir)!

	init := run(['wsl', '-e', 'sh', '-lc', 'mkdir -p ${wsl_tmp}'])!
	if init.exit_code != 0 {
		eprintln('riscv_diff: cannot create ${wsl_tmp}: ${init.output}')
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
			eprintln('riscv_diff: ${name}: frontend failed: ${r1.output}')
			failed++
			continue
		}
		r2 := run([virc, 'compile', ir, obj, 'riscv64-linux-gnu'])!
		if r2.exit_code != 0 {
			eprintln('riscv_diff: ${name}: object emission failed: ${r2.output}')
			failed++
			continue
		}

		vcmd := 'riscv64-linux-gnu-gcc -static ${win_to_wsl(obj)} -o ${wsl_tmp}/${name}_v && qemu-riscv64 ${wsl_tmp}/${name}_v; echo EXIT=$?'
		rv := run(['wsl', '-e', 'sh', '-lc', vcmd])!
		vcode := exit_of(rv.output)

		gcmd := 'riscv64-linux-gnu-gcc -static ${win_to_wsl(src)} -o ${wsl_tmp}/${name}_g && qemu-riscv64 ${wsl_tmp}/${name}_g; echo EXIT=$?'
		rg := run(['wsl', '-e', 'sh', '-lc', gcmd])!
		gcode := exit_of(rg.output)

		if vcode != gcode {
			eprintln('riscv_diff: ${name}: MISMATCH vir=${vcode} gcc=${gcode}')
			eprintln('  vir output: ${rv.output.trim(' \t\r\n')}')
			eprintln('  gcc output: ${rg.output.trim(' \t\r\n')}')
			failed++
		} else {
			println('riscv_diff: ${name}: OK (exit ${vcode})')
		}
	}
	if failed > 0 {
		eprintln('riscv_diff: ${failed}/${total} failed')
		exit(1)
	}
	println('riscv_diff: ${total}/${total} matched cross-gcc under qemu-riscv64')
}
