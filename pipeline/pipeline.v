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
import dwarf

// compile_module optimizes `m`, lowers it for `triple`, and writes a
// relocatable object to `path`. Supported: amd64 (ELF/COFF/MachO) and
// riscv64-linux-gnu (ELF).
pub fn compile_module(mut m ssa.Module, triple string, path string) ! {
	compile_module_lines(mut m, triple, path, map[int]int{})!
}

// compile_module_lines lowers like compile_module and emits a DWARF line
// table from the frontend's line table (SSA instruction value id to source
// line). Modules parsed from `.vir` text carry no lines; pass an empty map
// and only the line program shell is emitted.
pub fn compile_module_lines(mut m ssa.Module, triple string, path string, lines map[int]int) ! {
	t := target.parse_triple(triple)!
	if t.arch != .amd64 && t.arch != .riscv64 {
		return error('vir: object emission supports amd64 and riscv64, got ${t.arch}')
	}
	if t.arch == .riscv64 && t.os != .linux {
		return error('vir: riscv64 objects are linux-only in v1, got ${t.os}')
	}

	optimize.optimize(mut m)
	out := lower_module(mut m, t, lines)!

	match t.os {
		.linux {
			write_elf(out, t, path)!
		}
		.windows {
			if t.arch != .amd64 {
				return error('vir: COFF objects support amd64 only, got ${t.arch}')
			}
			write_coff(out, path)!
		}
		.macos {
			if t.arch != .amd64 {
				return error('vir: MachO objects support amd64 only, got ${t.arch}')
			}
			write_macho(out, path)!
		}
		else {
			return error('vir: object writer for ${t.os} is not available yet')
		}
	}
}

// lower_module optimizes `m` and lowers it for `triple`, returning the raw
// emission for object writers and the JIT without touching the filesystem.
// The arch selects the emitter: riscv64 uses the RV64I backend.
pub fn lower_module(mut m ssa.Module, t target.Triple, lines map[int]int) !emit.EmitOutput {
	optimize.optimize(mut m)
	mut mm := mach.select_machine_lines(m, t, lines)!
	mach.allocate(mut mm)!
	mach.assert_no_vregs(mm)!
	if t.arch == .riscv64 {
		return emit.emit_riscv64(mm, t)!
	}
	return emit.emit_amd64(mm, t)!
}

// write_elf emits an ELF64 relocatable object.
fn write_elf(out emit.EmitOutput, t target.Triple, path string) ! {
	machine := if t.arch == .riscv64 { obj.em_riscv } else { obj.em_x86_64 }
	mut elf := obj.ElfObject.new(machine)
	if t.arch == .riscv64 {
		// Match the default cross toolchain (RVC + double-float ABI) so the
		// linker accepts our integer-only objects next to its CRT.
		elf.flags = u32(0x5)
	}
	elf.text_data = out.text
	dwarf_secs := dwarf.build(out.syms, out.line_rows, 'vir 0.1.0', '.', 'vir-module')
	elf.debug_info = dwarf_secs.info
	elf.debug_abbrev = dwarf_secs.abbrev
	elf.debug_line = dwarf_secs.line
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

// write_coff emits a Windows/amd64 COFF object. Unlike ELF Rela, COFF keeps
// the addend inside the relocation field, so patch it into the text first.
fn write_coff(out emit.EmitOutput, path string) ! {
	mut coff := obj.CoffObject.new(obj.image_file_machine_amd64)
	coff.text_data = out.text
	for r in out.relocs {
		v := u32(r.addend)
		coff.text_data[r.offset] = u8(v)
		coff.text_data[r.offset + 1] = u8(v >> 8)
		coff.text_data[r.offset + 2] = u8(v >> 16)
		coff.text_data[r.offset + 3] = u8(v >> 24)
	}
	mut coff_idx := []int{len: out.syms.len}
	for i, sym in out.syms {
		coff_idx[i] = if sym.is_undefined {
			coff.add_undefined(sym.name)
		} else {
			coff.add_symbol(sym.name, u32(sym.offset), sym.is_func, 1)
		}
	}
	for r in out.relocs {
		if r.sym < 0 || r.sym >= coff_idx.len {
			return error('vir: relocation at ${r.offset} names bad symbol ${r.sym}')
		}
		coff.add_text_reloc(r.offset, coff_idx[r.sym], obj.image_rel_amd64_rel32)
	}
	coff.write(path)!
}

// write_macho emits a macOS/amd64 MachO object. x86_64 MachO relocations
// carry their PC-relative addend implicitly, so the text is left as emitted.
fn write_macho(out emit.EmitOutput, path string) ! {
	mut mo := obj.MachObject.new()
	mo.text_data = out.text
	mut macho_idx := []int{len: out.syms.len}
	for i, sym in out.syms {
		// Darwin C symbols carry a leading underscore.
		name := if sym.name.starts_with('_') { sym.name } else { '_' + sym.name }
		macho_idx[i] = if sym.is_undefined {
			mo.add_undefined(name)
		} else {
			mo.add_symbol(name, u64(sym.offset), sym.is_func)
		}
	}
	for r in out.relocs {
		if r.sym < 0 || r.sym >= macho_idx.len {
			return error('vir: relocation at ${r.offset} names bad symbol ${r.sym}')
		}
		mo.add_text_reloc(r.offset, macho_idx[r.sym], r.typ)
	}
	mo.write(path)!
}
