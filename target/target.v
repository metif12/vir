module target

// Arch lists architectures used by vir. riscv64 is explicitly post-v1.
pub enum Arch {
	unknown
	amd64
	arm64
}

// Os lists operating systems used by vir.
pub enum Os {
	unknown
	linux
	macos
	windows
}

// Triple is a parsed arch-os-abi target triple.
pub struct Triple {
pub:
	arch Arch
	os   Os
	abi  string
}

// parse_triple parses an arch-os-abi triple with common aliases.
// `x86_64` -> `amd64`, `aarch64` -> `arm64`, `macosx` -> `macos`,
// `win32`/`win64` -> `windows`.
pub fn parse_triple(s string) !Triple {
	parts := s.split('-')
	if parts.len != 3 {
		return error('vir: bad triple `${s}`, want arch-os-abi')
	}
	return Triple{
		arch: parse_arch(parts[0])!
		os:   parse_os(parts[1])!
		abi:  parts[2]
	}
}

// parse_arch parses one architecture name.
fn parse_arch(s string) !Arch {
	return match s {
		'amd64', 'x86_64' { Arch.amd64 }
		'arm64', 'aarch64' { Arch.arm64 }
		else { return error('vir: unsupported arch `${s}` (v1: amd64, arm64)') }
	}
}

// parse_os parses one operating system name.
fn parse_os(s string) !Os {
	return match s {
		'linux' { Os.linux }
		'macos', 'macosx', 'darwin' { Os.macos }
		'windows', 'win32', 'win64' { Os.windows }
		else { return error('vir: unsupported os `${s}` (v1: linux, macos, windows)') }
	}
}

// CallConvKind lists calling conventions used by vir.
pub enum CallConvKind {
	unknown
	sysv_amd64
	win64
	aapcs64
}

// PhysReg is one physical register: an arch-specific index into the
// integer or float bank.
pub struct PhysReg {
pub:
	arch     Arch
	index    int
	is_float bool
}

// name returns the assembler name of a physical register.
pub fn (r PhysReg) name() string {
	if r.arch == .amd64 && !r.is_float {
		names := ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi', 'r8',
			'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15']
		if r.index >= 0 && r.index < names.len {
			return names[r.index]
		}
	}
	if r.arch == .amd64 && r.is_float {
		if r.index >= 0 && r.index < 16 {
			return 'xmm${r.index}'
		}
	}
	if r.arch == .arm64 && !r.is_float {
		if r.index >= 0 && r.index < 31 {
			return 'x${r.index}'
		}
	}
	if r.arch == .arm64 && r.is_float {
		if r.index >= 0 && r.index < 32 {
			return 'v${r.index}'
		}
	}
	return 'badreg'
}

// CallConv describes how arguments and return values cross calls.
pub struct CallConv {
pub:
	kind           CallConvKind
	int_arg_regs   []PhysReg
	float_arg_regs []PhysReg
	int_ret_regs   []PhysReg
	float_ret_regs []PhysReg
	stack_align    int
	shadow_space   int
	red_zone       int
}

// callconv_for returns the calling convention for a triple. On amd64 the
// abi field selects the flavor (`msvc` -> Win64, anything else -> SysV);
// on arm64 it is always AAPCS64.
pub fn callconv_for(t Triple) !CallConv {
	if t.arch == .amd64 {
		if t.abi == 'msvc' {
			return CallConv{
				kind:           .win64
				int_arg_regs:   [PhysReg{arch: .amd64, index: 1}, PhysReg{
					arch: .amd64,
					index: 2
				}, PhysReg{arch: .amd64, index: 8}, PhysReg{arch: .amd64, index: 9}]
				float_arg_regs: [PhysReg{arch: .amd64, index: 0, is_float: true},
					PhysReg{arch: .amd64, index: 1, is_float: true}, PhysReg{
					arch: .amd64,
					index: 2,
					is_float: true
				}, PhysReg{arch: .amd64, index: 3, is_float: true}]
				int_ret_regs:   [PhysReg{arch: .amd64, index: 0}]
				stack_align:    16
				shadow_space:   32
			}
		}
		return CallConv{
			kind:           .sysv_amd64
			int_arg_regs:   [PhysReg{arch: .amd64, index: 7}, PhysReg{
				arch: .amd64,
				index: 6
			}, PhysReg{arch: .amd64, index: 2}, PhysReg{arch: .amd64, index: 1},
				PhysReg{arch: .amd64, index: 8}, PhysReg{arch: .amd64, index: 9}]
			float_arg_regs: [PhysReg{arch: .amd64, index: 0, is_float: true},
				PhysReg{arch: .amd64, index: 1, is_float: true}, PhysReg{
				arch: .amd64,
				index: 2,
				is_float: true
			}, PhysReg{arch: .amd64, index: 3, is_float: true}, PhysReg{
				arch: .amd64,
				index: 4,
				is_float: true
			}, PhysReg{arch: .amd64, index: 5, is_float: true}, PhysReg{
				arch: .amd64,
				index: 6,
				is_float: true
			}, PhysReg{arch: .amd64, index: 7, is_float: true}]
			int_ret_regs:   [PhysReg{arch: .amd64, index: 0}]
			stack_align:    16
			red_zone:       128
		}
	}
	if t.arch == .arm64 {
		mut int_regs := []PhysReg{}
		for i in 0 .. 8 {
			int_regs << PhysReg{arch: .arm64, index: i}
		}
		mut float_regs := []PhysReg{}
		for i in 0 .. 8 {
			float_regs << PhysReg{arch: .arm64, index: i, is_float: true}
		}
		return CallConv{
			kind:           .aapcs64
			int_arg_regs:   int_regs
			float_arg_regs: float_regs
			int_ret_regs:   [PhysReg{arch: .arm64, index: 0}]
			stack_align:    16
		}
	}
	return error('vir: no calling convention for ${t.arch}')
}

// ArgKind lists argument classes for calling convention assignment.
pub enum ArgKind {
	int_kind
	float_kind
}

// Arg is one call argument: its class and its width in bytes.
pub struct Arg {
pub:
	kind  ArgKind
	width int
}

// ArgLoc is where one argument goes: a register or a stack slot.
pub struct ArgLoc {
pub:
	has_reg      bool
	reg          PhysReg
	stack_offset int
}

// assign_args maps arguments to registers or 8-byte stack slots in order.
// Integer and float arguments draw from separate banks. Widths above 8
// bytes are rejected.
pub fn assign_args(cc CallConv, args []Arg) ![]ArgLoc {
	mut out := []ArgLoc{}
	mut int_used := 0
	mut float_used := 0
	mut stack_slots := 0
	for a in args {
		if a.width <= 0 || a.width > 8 {
			return error('vir: unsupported argument width ${a.width}')
		}
		if a.kind == .int_kind && int_used < cc.int_arg_regs.len {
			out << ArgLoc{
				has_reg: true
				reg:     cc.int_arg_regs[int_used]
			}
			int_used++
			continue
		}
		if a.kind == .float_kind && float_used < cc.float_arg_regs.len {
			out << ArgLoc{
				has_reg: true
				reg:     cc.float_arg_regs[float_used]
			}
			float_used++
			continue
		}
		out << ArgLoc{
			stack_offset: stack_slots * 8
		}
		stack_slots++
	}
	return out
}
