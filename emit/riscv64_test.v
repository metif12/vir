module emit

import os
import cminus
import pipeline
import mach
import target

fn test_riscv_addi_encoding() {
	// addi x1, x0, 5 -> 0x00500093
	w := rv_i(5, 0, 0, 1, 0x13)!
	assert w == u32(0x00500093)
}

fn test_riscv_jal_encoding() {
	// jal x1, 0 -> 0x000000ef
	assert rv_jal(1, 0)! == u32(0x000000ef)
	// jal x0, +8 -> 0x0080006f
	assert rv_jal(0, 8)! == u32(0x0080006f)
}

fn test_riscv_branch_encoding() {
	// beq x1, x2, +8 -> 0x00208463
	assert rv_b(0, 1, 2, 8)! == u32(0x00208463)
}

fn test_riscv_r_type_encodings() {
	// add x3, x1, x2 -> 0x002081b3
	assert rv_r(0, 2, 1, 0, 3) == u32(0x002081b3)
	// sub x3, x1, x2 -> 0x402081b3
	assert rv_r(0x20, 2, 1, 0, 3) == u32(0x402081b3)
	// mul x3, x1, x2 -> 0x022081b3
	assert rv_r(1, 2, 1, 0, 3) == u32(0x022081b3)
}

fn test_riscv_ret_encoding() {
	// jalr x0, 0(ra) -> 0x00008067
	assert rv_i(0, 1, 0, 0, 0x67)! == u32(0x00008067)
}

fn test_riscv_ranges_rejected() {
	rv_jal(0, 1 << 21) or {
		assert err.msg().contains('out of range')
		return
	}
	assert false, 'expected jal range error'
}

fn riscv_object(src string, name string) ![]u8 {
	funcs := cminus.parse(src)!
	mut m := cminus.generate(funcs)!
	path := os.join_path(os.vtmp_dir(), 'vir_riscv_${os.getpid()}_${name}.o')
	pipeline.compile_module(mut m, 'riscv64-linux-gnu', path)!
	defer {
		os.rm(path) or {}
	}
	return os.read_bytes(path)!
}

fn test_riscv_object_is_riscv_elf() {
	src := os.read_file(os.join_path(@VMODROOT, 'testdata', 'cminus', 'add.c'))!
	buf := riscv_object(src, 'add')!
	assert buf[0] == 0x7f
	assert buf[1] == 0x45 // ELF magic
	// e_machine at offset 18 is EM_RISCV (243).
	machine := u16(buf[18]) | (u16(buf[19]) << 8)
	assert machine == 243
	// Thirteen sections: nine base plus four DWARF ones.
	assert u16(buf[60]) | (u16(buf[61]) << 8) == 13
}

fn r32(b []u8, off int) u32 {
	return u32(b[off]) | (u32(b[off + 1]) << 8) | (u32(b[off + 2]) << 16) | (u32(b[off + 3]) << 24)
}

fn test_riscv_frame_saves_above_spills() {
	// Regression test: spill slot 0 must live below the saved ra/fp pair.
	// An earlier layout mapped slot 0 onto the saved ra and crashed on
	// return; the prologue below pins saves at the frame top and slot 0
	// a full pair beneath them.
	t := target.parse_triple('riscv64-linux-gnu')!
	t0 := mach.Reg{ virt: -1, phys: target.PhysReg{ arch: .riscv64, index: 5 } }
	mm := mach.MachineModule{
		triple: 'riscv64-linux-gnu'
		funcs:  [
			mach.MachineFunc{
				name:        'f'
				stack_slots: 1
				blocks:      [
					mach.MachineBlock{
						id:     0
						name:   'entry'
						instrs: [
							mach.MachineInstr{
								op:   .store
								srcs: [
									mach.Operand{ kind: .reg, reg: t0 },
									mach.Operand{ kind: .slot, slot: 0 },
								]
							},
							mach.MachineInstr{
								op: .ret
							},
						]
					},
				]
			},
		]
	}
	out := emit_riscv64(mm, t)!
	// frame = 32: addi sp,sp,-32; sd s0,16(sp); sd ra,24(sp); addi s0,sp,32.
	assert r32(out.text, 0) == u32(0xFE010113)
	assert r32(out.text, 4) == u32(0x00813823)
	assert r32(out.text, 8) == u32(0x00113C23)
	assert r32(out.text, 12) == u32(0x02010413)
	// Slot 0 stores below the pair: sd t0,-24(s0).
	assert r32(out.text, 16) == u32(0xFE543423)
}
