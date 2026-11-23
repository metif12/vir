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

// FrontDebug carries frontend source information that the text and binary IR
// formats cannot represent: a line table (SSA instruction value id to source
// line) and a variable table (SSA instruction value id to the source-level
// variable names whose value it holds). Optimizer-created values and
// constants have no entries; consumers must tolerate missing keys.
pub struct FrontDebug {
pub mut:
	lines map[int]int
	vars  map[int][]string
}

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
	t := target_for(triple)!
	optimize.optimize(mut m)
	out := lower_module(mut m, t, lines)!
	write_object(out, t, []dwarf.DebugVar{}, path)!
}

// compile_module_debug lowers like compile_module_lines and additionally
// emits DWARF location lists for the frontend's tracked variables. Only the
// in-memory frontend path carries variable names; file-parsed modules get
// no location lists.
pub fn compile_module_debug(mut m ssa.Module, triple string, path string, dbg FrontDebug) ! {
	t := target_for(triple)!
	optimize.optimize(mut m)
	out := lower_module(mut m, t, dbg.lines)!
	vars := build_var_locs(m, dbg, out)!
	write_object(out, t, vars, path)!
}

// target_for parses a triple and enforces the v1 object-emission support:
// amd64 everywhere, riscv64 linux only.
fn target_for(triple string) !target.Triple {
	t := target.parse_triple(triple)!
	if t.arch != .amd64 && t.arch != .riscv64 {
		return error('vir: object emission supports amd64 and riscv64, got ${t.arch}')
	}
	if t.arch == .riscv64 && t.os != .linux {
		return error('vir: riscv64 objects are linux-only in v1, got ${t.os}')
	}
	return t
}

// write_object dispatches the lowered module to the OS object writer.
fn write_object(out emit.EmitOutput, t target.Triple, vars []dwarf.DebugVar, path string) ! {
	match t.os {
		.linux {
			write_elf(out, t, vars, path)!
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

// build_var_locs groups address rows by source variable into DWARF location
// lists. Each tracked SSA value contributes one range from the start of its
// defining instruction to the end of its last user, at the home recorded on
// its last defining row. Constants, arguments (covered by entry DIEs) and
// values without rows or homes are skipped.
fn build_var_locs(m &ssa.Module, dbg FrontDebug, out emit.EmitOutput) ![]dwarf.DebugVar {
	// Span per SSA instruction index.
	mut span_start := map[int]u64{}
	mut span_end := map[int]u64{}
	for r in out.addr_rows {
		if r.ssa_id <= 0 || r.ssa_id >= m.values.len {
			continue
		}
		idx := int(m.values[r.ssa_id].index)
		if idx < 0 {
			continue
		}
		start := u64(r.offset)
		end := start + u64(r.size)
		if idx !in span_start || start < span_start[idx] {
			span_start[idx] = start
		}
		if idx !in span_end || end > span_end[idx] {
			span_end[idx] = end
		}
	}
	// Home per SSA value: the location on its last defining row.
	mut home := map[int]emit.AddrRow{}
	for r in out.addr_rows {
		if r.ssa_id <= 0 || r.ssa_id >= m.values.len || !r.has_loc {
			continue
		}
		home[r.ssa_id] = r
	}
	mut by_name := map[string][]dwarf.VarRange{}
	mut var_func := map[string]string{}
	for vid, names in dbg.vars {
		if vid <= 0 || vid >= m.values.len {
			continue
		}
		v := m.values[vid]
		if v.kind != .instruction {
			continue
		}
		def_idx := int(v.index)
		if def_idx < 0 || def_idx >= m.instrs.len || def_idx !in span_start {
			continue
		}
		h := home[vid] or { continue }
		if h.is_reg && (h.reg < 0 || h.reg > 31) {
			continue
		}
		if !h.is_reg && (h.breg < 0 || h.breg > 31) {
			continue
		}
		start := span_start[def_idx]
		mut end := span_end[def_idx]
		for u in v.uses {
			uid := int(u)
			if uid <= 0 || uid >= m.values.len {
				continue
			}
			uv := m.values[uid]
			if uv.kind != .instruction {
				continue
			}
			uidx := int(uv.index)
			if uidx in span_end && span_end[uidx] > end {
				end = span_end[uidx]
			}
		}
		if end <= start {
			continue
		}
		// Owning function via defining instruction -> block -> parent.
		def_instr := m.instrs[int(v.index)]
		blk := int(def_instr.block)
		mut func_name := ''
		if blk >= 0 && blk < m.blocks.len {
			fidx := m.blocks[blk].parent
			if fidx >= 0 && fidx < m.funcs.len {
				func_name = m.funcs[fidx].name
			}
		}
		loc := dwarf.VarRange{
			start:  start
			end:    end
			is_reg: h.is_reg
			reg:    h.reg
			breg:   h.breg
			off:    h.off
		}
		for name in names {
			by_name[name] << loc
			var_func[name] = func_name
		}
	}
	// Deterministic order: sort variables by name, ranges by start address,
	// so repeated builds stay byte-identical.
	mut names := by_name.keys()
	names.sort()
	mut out_vars := []dwarf.DebugVar{}
	for name in names {
		mut ranges := by_name[name].clone()
		ranges.sort(a.start < b.start)
		out_vars << dwarf.DebugVar{ func: var_func[name], name: name, ranges: ranges }
	}
	return out_vars
}

// write_elf emits an ELF64 relocatable object.
fn write_elf(out emit.EmitOutput, t target.Triple, vars []dwarf.DebugVar, path string) ! {
	machine := if t.arch == .riscv64 { obj.em_riscv } else { obj.em_x86_64 }
	mut elf := obj.ElfObject.new(machine)
	if t.arch == .riscv64 {
		// Match the default cross toolchain (RVC + double-float ABI) so the
		// linker accepts our integer-only objects next to its CRT.
		elf.flags = u32(0x5)
	}
	elf.text_data = out.text
	dwarf_secs := dwarf.build(out.syms, out.line_rows, vars, 'vir 0.1.0', '.', 'vir-module')
	elf.debug_info = dwarf_secs.info
	elf.debug_abbrev = dwarf_secs.abbrev
	elf.debug_line = dwarf_secs.line
	elf.debug_loc = dwarf_secs.loc
	elf.debug_loc = dwarf_secs.loc
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
