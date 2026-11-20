module bitcode

import os
import cminus
import vmini
import vssa.ssa

fn roundtrip(name string, src string, is_c bool) !string {
	funcs := if is_c { cminus.parse(src)! } else { vmini.parse(src)! }
	mut m := cminus.generate(funcs)!
	before := ssa.module_to_text(m)!
	bytes := encode(m)!
	mut decoded := decode(bytes)!
	after := ssa.module_to_text(decoded)!
	assert after == before, 'bitcode round-trip mismatch for ${name}'
	return before
}

fn fixture(name string) !string {
	dir := if name.ends_with('.c') { 'cminus' } else { 'vmini' }
	return os.read_file(os.join_path(@VMODROOT, 'testdata', dir, name))!
}

fn test_bitcode_cminus_roundtrip() {
	text := roundtrip('func.c', fixture('func.c')!, true)!
	assert text.contains(' call ')
}

fn test_bitcode_vmini_loop_roundtrip() {
	text := roundtrip('while.v', fixture('while.v')!, false)!
	assert text.contains(' lt ')
	assert text.contains(' jmp ')
}

fn test_bitcode_rejects_globals() {
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	m.add_global('counter', i32_t)
	encode(m) or {
		assert err.msg().contains('globals')
		return
	}
	assert false, 'expected globals to be rejected'
}
