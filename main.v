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
	eprintln('virc: usage: virc [--version] | [verify <file.vir>]')
	exit(1)
}
