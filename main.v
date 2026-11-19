module main

import os
import vssa.optimize
import vssa.ssa

const vir_version = '0.1.0'

fn main() {
	args := os.args[1..]
	if args.len == 0 || args[0] == '--version' {
		println('virc ${vir_version} (M0 bootstrap)')
		return
	}
	if args[0] == 'verify' && args.len == 2 {
		src := os.read_file(args[1]) or {
			eprintln('virc: cannot read ${args[1]}: ${err.msg()}')
			exit(1)
		}
		m := ssa.module_from_text(src) or {
			eprintln('virc: parse error: ${err.msg()}')
			exit(1)
		}
		errors := optimize.verify(m)
		if errors.len == 0 {
			println('virc: ${args[1]}: OK')
			return
		}
		for e in errors {
			eprintln('virc: ${e}')
		}
		exit(1)
	}
	if args[0] == 'opt' && (args.len == 2 || args.len == 3) {
		src := os.read_file(args[1]) or {
			eprintln('virc: cannot read ${args[1]}: ${err.msg()}')
			exit(1)
		}
		mut m := ssa.module_from_text(src) or {
			eprintln('virc: parse error: ${err.msg()}')
			exit(1)
		}
		optimize.optimize(mut m)
		out := ssa.module_to_text(m) or {
			eprintln('virc: print error: ${err.msg()}')
			exit(1)
		}
		if args.len == 3 {
			os.write_file(args[2], out) or {
				eprintln('virc: cannot write ${args[2]}: ${err.msg()}')
				exit(1)
			}
			return
		}
		print(out)
		return
	}
	eprintln('virc: usage: virc [--version] | [verify <file.vir>] | [opt <file.vir> [out.vir]]')
	exit(1)
}
