module target

fn test_parse_triple_aliases() {
	t := parse_triple('x86_64-linux-gnu')!
	assert t.arch == .amd64
	assert t.os == .linux
	assert t.abi == 'gnu'
	a := parse_triple('aarch64-macos-aapcs64')!
	assert a.arch == .arm64
	assert a.os == .macos
	w := parse_triple('amd64-win64-msvc')!
	assert w.arch == .amd64
	assert w.os == .windows
}

fn test_parse_triple_rejects() {
	parse_triple('amd64-linux') or {
		assert err.msg().contains('arch-os-abi')
		return
	}
	assert false, 'expected error for short triple'
	parse_triple('riscv64-linux-gnu') or {
		assert err.msg().contains('unsupported arch')
		return
	}
	assert false, 'expected error for riscv64'
	parse_triple('amd64-plan9-gnu') or {
		assert err.msg().contains('unsupported os')
		return
	}
	assert false, 'expected error for bad os'
}

fn test_sysv_arg_assignment() {
	cc := callconv_for(parse_triple('amd64-linux-gnu')!)!
	mut args := []Arg{}
	for _ in 0 .. 8 {
		args << Arg{kind: .int_kind, width: 8}
	}
	locs := assign_args(cc, args)!
	assert locs.len == 8
	assert locs[0].has_reg && locs[0].reg.name() == 'rdi'
	assert locs[5].has_reg && locs[5].reg.name() == 'r9'
	assert !locs[6].has_reg && locs[6].stack_offset == 0
	assert !locs[7].has_reg && locs[7].stack_offset == 8
	assert cc.shadow_space == 0
	assert cc.red_zone == 128
	flocs := assign_args(cc, [
		Arg{kind: .float_kind, width: 8},
		Arg{kind: .float_kind, width: 4},
	])!
	assert flocs[0].reg.name() == 'xmm0'
	assert flocs[1].reg.name() == 'xmm1'
}

fn test_win64_arg_assignment() {
	cc := callconv_for(parse_triple('amd64-windows-msvc')!)!
	mut args := []Arg{}
	for _ in 0 .. 5 {
		args << Arg{kind: .int_kind, width: 4}
	}
	locs := assign_args(cc, args)!
	assert locs[0].reg.name() == 'rcx'
	assert locs[3].reg.name() == 'r9'
	assert !locs[4].has_reg && locs[4].stack_offset == 0
	assert cc.shadow_space == 32
	assert cc.red_zone == 0
}

fn test_aapcs64_arg_assignment() {
	cc := callconv_for(parse_triple('aarch64-linux-aapcs64')!)!
	mut args := []Arg{}
	for _ in 0 .. 9 {
		args << Arg{kind: .int_kind, width: 8}
	}
	locs := assign_args(cc, args)!
	assert locs[0].reg.name() == 'x0'
	assert locs[7].reg.name() == 'x7'
	assert !locs[8].has_reg && locs[8].stack_offset == 0
}
