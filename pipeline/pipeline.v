module pipeline

// The single lowering pipeline shared by the virc driver and the libvir C API:
// parse is done by the caller; everything from optimization through the ELF
// object writer lives here so both front ends stay in lockstep.

import vssa.ssa
import vssa.optimize
import target
import mach
import emit
import obj

// compile_module optimizes `m`, lowers it for `triple`, and writes an ELF64
// relocatable object to `path`. In v1 only amd64 targets can be emitted.
pub fn compile_module(mut m ssa.Module, triple string, path string) ! {
	t := target.parse_triple(triple)!
	if t.arch != .amd64 {
		return error('vir: object emission supports amd64 only, got ${t.arch}')
	}

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
