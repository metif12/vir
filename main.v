module main

import os

const vir_version = '0.1.0'

fn main() {
	args := os.args[1..]
	if args.len == 0 || args[0] == '--version' {
		println('virc ${vir_version} (M0 bootstrap)')
		return
	}
	eprintln('virc: M0 bootstrap — full driver lands in M4 (see ROADMAP.md)')
	exit(1)
}
