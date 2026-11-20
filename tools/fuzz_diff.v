module main

// Seeded fuzz + differential harness. Generates random C-minus programs,
// compiles them through vir (frontend -> .vir -> ELF object), links and runs
// the object with gcc in WSL, then compares the exit code against gcc
// compiling the same source. Failures are saved for minimization.
//
// Run: v run tools/fuzz_diff.v [iterations] [seed]

import os

const wsl_tmp = '/tmp/vir_fuzz'

struct Rng {
mut:
	seed u64
	uid  int
}

fn (mut r Rng) next_u() u64 {
	r.seed = r.seed * 6364136223846793005 + 1442695040888963407
	return r.seed >> 33
}

fn (mut r Rng) pick(n int) int {
	return int(r.next_u() % u64(n))
}

fn (mut r Rng) expr(vars []string, depth int) string {
	if depth <= 0 || r.pick(4) == 0 {
		if vars.len > 0 && r.pick(2) == 0 {
			return vars[r.pick(vars.len)]
		}
		return '${r.pick(12)}'
	}
	ops := ['+', '-', '*', '/', '%']
	op := ops[r.pick(ops.len)]
	lhs := r.expr(vars, depth - 1)
	// Keep divisors non-zero and small so results stay in range.
	rhs := if op == '/' || op == '%' { '${1 + r.pick(4)}' } else { r.expr(vars, depth - 1) }
	return '(${lhs} ${op} ${rhs})'
}

fn (mut r Rng) stmt(vars []string, depth int) []string {
	mut out := []string{}
	kind := r.pick(3)
	if kind == 0 || depth >= 2 {
		out << '    ${vars[r.pick(vars.len)]} = ${r.expr(vars, 2)};'
	} else if kind == 1 {
		out << '    if (${r.expr(vars, 1)} > ${r.pick(5)}) {'
		out << '      ${vars[r.pick(vars.len)]} = ${r.expr(vars, 1)};'
		out << '    } else {'
		out << '      ${vars[r.pick(vars.len)]} = ${r.expr(vars, 1)};'
		out << '    }'
	} else {
		r.uid++
		c := 'loop${r.uid}'
		out << '    int ${c} = 0;'
		out << '    while (${c} < ${1 + r.pick(4)}) {'
		out << '      ${c} = ${c} + 1;'
		out << '      ${vars[r.pick(vars.len)]} = ${r.expr(vars, 1)};'
		out << '    }'
	}
	return out
}

fn (mut r Rng) program() string {
	mut lines := ['int main() {']
	n := 1 + r.pick(3)
	mut vars := []string{}
	for i in 0 .. n {
		v := 'v${i}'
		vars << v
		lines << '  int ${v} = ${r.pick(12)};'
	}
	count := 1 + r.pick(4)
	for _ in 0 .. count {
		lines << r.stmt(vars, 0)
	}
	lines << '  return ${vars[0]};'
	lines << '}'
	return lines.join('\n') + '\n'
}

fn win_to_wsl(p string) string {
	s := p.replace('\\', '/')
	if s.len > 1 && s[1] == `:` {
		return '/mnt/${s[0..1].to_lower()}${s[2..]}'
	}
	return s
}

fn run(cmd []string) !os.Result {
	return os.exec_opt(cmd)
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
	mut iterations := 40
	mut seed := u64(20261120)
	if os.args.len > 1 {
		iterations = os.args[1].int()
	}
	if os.args.len > 2 {
		seed = os.args[2].u64()
	}
	root := @VMODROOT
	virc := os.join_path(root, 'virc.exe')
	out_dir := os.join_path(os.getenv('LOCALAPPDATA'), 'Temp', 'opencode', 'vir-fuzz')
	fail_dir := os.join_path(root, 'testdata', 'fuzz-failures')
	os.mkdir_all(out_dir)!
	init := run(['wsl', '-e', 'sh', '-lc', 'mkdir -p ${wsl_tmp}'])!
	if init.exit_code != 0 {
		eprintln('fuzz_diff: cannot create ${wsl_tmp}: ${init.output}')
		exit(1)
	}

	mut rng := Rng{ seed: seed }
	mut mismatches := 0
	mut blocked := 0
	for i in 0 .. iterations {
		src := rng.program()
		src_path := os.join_path(out_dir, 'case.c')
		ir_path := os.join_path(out_dir, 'case.vir')
		obj_path := os.join_path(out_dir, 'case.o')
		os.write_file(src_path, src)!

		r1 := run([virc, 'cminus', src_path, ir_path]) or {
			blocked++
			continue
		}
		r2 := run([virc, 'compile', ir_path, obj_path]) or {
			blocked++
			continue
		}
		if r1.exit_code != 0 || r2.exit_code != 0 {
			os.write_file(os.join_path(fail_dir, 'reject_${i}.c'), src) or {}
			mismatches++
			continue
		}

		vcmd := 'gcc ${win_to_wsl(obj_path)} -o ${wsl_tmp}/fz && ${wsl_tmp}/fz; echo EXIT=$?'
		rv := run(['wsl', '-e', 'sh', '-lc', vcmd]) or {
			blocked++
			continue
		}
		gcmd := 'gcc ${win_to_wsl(src_path)} -o ${wsl_tmp}/fg && ${wsl_tmp}/fg; echo EXIT=$?'
		rg := run(['wsl', '-e', 'sh', '-lc', gcmd]) or {
			blocked++
			continue
		}
		vc := exit_of(rv.output)
		gc := exit_of(rg.output)
		if vc != gc {
			os.mkdir_all(fail_dir)!
			os.write_file(os.join_path(fail_dir, 'mismatch_${i}.c'), src)!
			eprintln('fuzz_diff: case ${i}: MISMATCH vir=${vc} gcc=${gc}')
			mismatches++
		}
	}
	println('fuzz_diff: seed=${seed} cases=${iterations} mismatches=${mismatches} blocked=${blocked}')
	if mismatches > 0 {
		exit(1)
	}
}
