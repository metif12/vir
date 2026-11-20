module libvir

// C ABI for vir (M5). Frontends call vir_parse / vir_optimize / vir_verify /
// vir_compile / vir_module_free through vir.h; no V runtime is exposed.
// Module handles are small integer ids carried as voidptr. The modules live in
// a global map so V's GC keeps them alive for as long as C holds a handle.

import vssa.ssa
import vssa.optimize
import pipeline

const abi_version = 1

__global (
	modules     map[u64]&ssa.Module
	next_handle = u64(1)
	last_error  = ''
)

fn init() {
	modules = map[u64]&ssa.Module{}
	next_handle = 1
	last_error = ''
}

fn set_error(msg string) {
	last_error = msg
}

fn clear_error() {
	last_error = ''
}

fn find_module(h voidptr) ?&ssa.Module {
	if isnil(h) {
		return none
	}
	if m := modules[u64(h)] {
		return m
	}
	return none
}

@[export: 'vir_abi_version']
fn c_abi_version() int {
	return abi_version
}

@[export: 'vir_parse']
fn c_parse(src charptr) voidptr {
	if isnil(src) {
		set_error('vir: null source')
		return voidptr(0)
	}
	text := unsafe { src.vstring() }
	mut m := ssa.module_from_text(text) or {
		set_error(err.msg())
		return voidptr(0)
	}
	id := next_handle
	next_handle++
	modules[id] = m
	clear_error()
	return voidptr(id)
}

@[export: 'vir_optimize']
fn c_optimize(h voidptr) int {
	mut m := find_module(h) or {
		set_error('vir: invalid module handle')
		return 1
	}
	optimize.optimize(mut m)
	clear_error()
	return 0
}

@[export: 'vir_verify']
fn c_verify(h voidptr) int {
	m := find_module(h) or {
		set_error('vir: invalid module handle')
		return 1
	}
	errors := optimize.verify(m)
	if errors.len > 0 {
		set_error(errors[0].str())
		return 1
	}
	clear_error()
	return 0
}

@[export: 'vir_compile']
fn c_compile(h voidptr, triple charptr, out_path charptr) int {
	mut m := find_module(h) or {
		set_error('vir: invalid module handle')
		return 1
	}
	if isnil(triple) || isnil(out_path) {
		set_error('vir: null triple or output path')
		return 1
	}
	tr := unsafe { triple.vstring() }
	path := unsafe { out_path.vstring() }
	pipeline.compile_module(mut m, tr, path) or {
		set_error(err.msg())
		return 1
	}
	clear_error()
	return 0
}

@[export: 'vir_last_error']
fn c_last_error() charptr {
	return last_error.str
}

@[export: 'vir_module_free']
fn c_module_free(h voidptr) {
	if isnil(h) {
		return
	}
	modules.delete(u64(h))
	clear_error()
}
