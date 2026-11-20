module main

// Microbenchmarks for the M7 milestone: average end-to-end vir compile time
// (frontend + object emission) versus gcc compile time on the C-minus corpus,
// plus emitted object sizes. Process startup is included on both sides.
//
// Run: v run tools/bench.v [repetitions]

import os
import time

fn win_to_wsl(p string) string {
	s := p.replace('\\', '/')
	if s.len > 1 && s[1] == `:` {
		return '/mnt/${s[0..1].to_lower()}${s[2..]}'
	}
	return s
}

fn main() {
	mut reps := 5
	if os.args.len > 1 {
		reps = os.args[1].int()
	}
	root := @VMODROOT
	virc := os.join_path(root, 'virc.exe')
	dir := os.join_path(root, 'testdata', 'cminus')
	out_dir := os.join_path(os.getenv('LOCALAPPDATA'), 'Temp', 'opencode', 'vir-bench')
	os.mkdir_all(out_dir)!
	os.exec_opt(['wsl', '-e', 'sh', '-lc', 'mkdir -p /tmp/vir_bench']) or {}

	files := os.ls(dir)!
	println('fixture          vir_us   gcc_us   object_bytes')
	for file in files {
		if !file.ends_with('.c') {
			continue
		}
		src := os.join_path(dir, file)
		ir := os.join_path(out_dir, 'bench.vir')
		obj := os.join_path(out_dir, 'bench.o')

		t0 := time.now()
		for _ in 0 .. reps {
			r1 := os.exec_opt([virc, 'cminus', src, ir]) or { continue }
			if r1.exit_code != 0 {
				continue
			}
			os.exec_opt([virc, 'compile', ir, obj]) or {}
		}
		vir_us := time.since(t0).microseconds() / reps

		cmd := 'gcc -c ${win_to_wsl(src)} -o /tmp/vir_bench/bench.o'
		t1 := time.now()
		for _ in 0 .. reps {
			os.exec_opt(['wsl', '-e', 'sh', '-lc', cmd]) or {}
		}
		gcc_us := time.since(t1).microseconds() / reps

		size := os.file_size(obj)
		println('${file:<16} ${vir_us:>7} ${gcc_us:>8} ${size:>12}')
	}
}
