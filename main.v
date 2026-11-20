module main

import os
import vssa.optimize
import vssa.ssa
import target
import mach
import emit
import obj

const vir_version = '0.1.0'

// default_triple is the target used by `virc compile` unless overridden.
const default_triple = 'amd64-linux-gnu'

// compile_file parses `src`, runs the optimization pipeline, lowers it through
// selection and register allocation, emits amd64 machine code, and writes an
// ELF64 relocatable object to `path`.
fn compile_file(src string, triple string, path string) ! {
	t := target.parse_triple(triple)!
	if t.arch != .amd64 {
		return error('vir: object emission supports amd64 only, got ${t.arch}')
	}

	mut m := ssa.module_from_text(src)!
	optimize.optimize(mut m)
	mut mm := mach.select_machine(m, t)!
	mach.allocate(mut mm)!
	mach.assert_no_vregs(mm)!
	out := emit.emit_amd64(mm, t)!

	mut elf := obj.ElfObject.new(obj.em_x86_64)
	elf.text_data = out.text
	// ELF reserves symbol index 0 for the null symbol, so emitter indices
	// shift by one on their way into the object's symbol table.
	mut elf_idx := []int{len: out.syms.len}
	for i, sym in out.syms {
		elf_idx[i] = if sym.is_undefined {
			elf.add_undefined(sym.name)
		} else {
			elf.add_symbol(sym.name, u64(sym.offset), sym.is_func, 1)
		}
	}
	for r in out.relocs {
		if r.sym < 0 || r.sym >= elf_idx.len {
			return error('vir: relocation at ${r.offset} names bad symbol ${r.sym}')
		}
		elf.add_text_reloc(u64(r.offset), elf_idx[r.sym], r.typ, r.addend)
	}
	elf.write(path)!
}

fn main() {
	args := os.args[1..]
	if args.len == 0 || args[0] == '--version' {
		println('virc ${vir_version}')
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
	if args[0] == 'compile' && (args.len == 3 || args.len == 4) {
		src := os.read_file(args[1]) or {
			eprintln('virc: cannot read ${args[1]}: ${err.msg()}')
			exit(1)
		}
		triple := if args.len == 4 { args[3] } else { default_triple }
		compile_file(src, triple, args[2]) or {
			eprintln('virc: compile failed: ${err.msg()}')
			exit(1)
		}
		println('virc: wrote ${args[2]}')
		return
	}
	eprintln('virc: usage: virc [--version] | [verify <file.vir>] | [opt <file.vir> [out.vir]] | [compile <in.vir> <out.o> [triple]]')
	exit(1)
}
