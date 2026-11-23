module jit

// In-process JIT executor for vir (post-v1). v1 runs Windows/amd64 only: the
// emitted text is copied to a RWX region, internal PC32/PLT32 relocations are
// applied against the loaded base, and the entry symbol is called as
// `fn () int`. Calls to undefined (external) symbols are rejected — linking
// against system libraries stays the object-file path's job.
//
// Only PC-relative relocations are supported, which is all the emitter
// produces. Their value (S + A - P) is base-independent, so the JIT never
// needs the absolute load address for the math, only for the call.

import emit

#include <windows.h>

fn C.VirtualAlloc(addr voidptr, size u64, alloctype u32, protect u32) voidptr
fn C.VirtualFree(addr voidptr, size u64, freetype u32) int
fn C.memcpy(dst voidptr, src voidptr, n u64) voidptr

const mem_commit = u32(0x1000)
const mem_reserve = u32(0x2000)
const mem_release = u32(0x8000)
const page_exec_rw = u32(0x40)

// EntryFn is the shape of every JIT entry point: no arguments, int result,
// matching the C-minus `int main()` fixtures.
type EntryFn = fn () int

// run loads `out` into executable memory, applies its relocations, calls the
// `entry` symbol and frees the region before returning its exit code.
pub fn run(out &emit.EmitOutput, entry string) !int {
	$if windows {
		return run_windows(out, entry)!
	} $else {
		return error('vir: jit supports windows/amd64 only in v1')
	}
}

fn run_windows(out &emit.EmitOutput, entry string) !int {
	if out.text.len == 0 {
		return error('vir: jit has no code to run')
	}
	mut entry_off := -1
	for s in out.syms {
		if s.is_func && !s.is_undefined && s.name == entry {
			entry_off = int(s.offset)
			break
		}
	}
	if entry_off < 0 {
		return error('vir: jit entry `${entry}` not found')
	}
	base := C.VirtualAlloc(voidptr(0), u64(out.text.len), mem_commit | mem_reserve,
		page_exec_rw)
	if base == voidptr(0) {
		return error('vir: jit VirtualAlloc failed')
	}
	C.memcpy(base, out.text.data, u64(out.text.len))
	apply_relocs(base, out)!
	code := EntryFn(unsafe { voidptr(u64(base) + u64(entry_off)) })
	got := code()
	C.VirtualFree(base, 0, mem_release)
	return got
}

// apply_relocs patches every relocation in place. For S + A - P relocations
// against internal symbols the load base cancels out, so only the offsets
// matter; external symbols have no address in-process and are rejected.
fn apply_relocs(base voidptr, out &emit.EmitOutput) ! {
	site_base := u64(base)
	for r in out.relocs {
		if r.sym < 0 || r.sym >= out.syms.len {
			return error('vir: jit relocation names bad symbol ${r.sym}')
		}
		s := out.syms[r.sym]
		if s.is_undefined {
			return error('vir: jit cannot resolve external `${s.name}` in v1')
		}
		if r.typ != emit.r_x86_64_pc32 && r.typ != emit.r_x86_64_plt32 {
			return error('vir: jit does not support relocation type ${r.typ}')
		}
		v := i64(s.offset) + r.addend - i64(r.offset)
		patch := site_base + u64(r.offset)
		unsafe {
			b := &u8(patch)
			b[0] = u8(v)
			b[1] = u8(v >> 8)
			b[2] = u8(v >> 16)
			b[3] = u8(v >> 24)
		}
	}
}
