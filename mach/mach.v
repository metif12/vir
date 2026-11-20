module mach

import target

// frame_ptr_vreg is the reserved virtual register for the frame pointer.
// Stack argument slots address off it until frame lowering binds it.
const frame_ptr_vreg = -100

// MachineOp lists amd64 machine ops used by vir. This is the v1 integer
// subset; the set grows with the selector.
pub enum MachineOp {
	mov
	movi
	add
	sub
	imul
	neg
	cmp
	setcc
	jmp
	jcc
	call
	ret
	load
	store
}

// Cond lists branch conditions used by vir.
pub enum Cond {
	eq
	ne
	lt
	le
	gt
	ge
	ult
	ule
	ugt
	uge
}

// cond_name returns the text form of a condition.
pub fn cond_name(c Cond) string {
	return match c {
		.eq { 'eq' }
		.ne { 'ne' }
		.lt { 'lt' }
		.le { 'le' }
		.gt { 'gt' }
		.ge { 'ge' }
		.ult { 'ult' }
		.ule { 'ule' }
		.ugt { 'ugt' }
		.uge { 'uge' }
	}
}

// Reg is a virtual register (id >= 0) or a physical one (id < 0).
pub struct Reg {
pub:
	virt int
	phys target.PhysReg
}

// vreg creates a virtual register.
pub fn vreg(id int) Reg {
	return Reg{virt: id}
}

// preg creates a physical register operand.
pub fn preg(r target.PhysReg) Reg {
	return Reg{virt: -1, phys: r}
}

// is_phys reports whether a register is physical.
pub fn (r Reg) is_phys() bool {
	return r.virt < 0
}

// OperandKind lists machine operand kinds used by vir.
pub enum OperandKind {
	reg
	imm
	mem
	symbol
	slot
}

// Operand is one machine instruction operand. Slots are spilled virtual
// registers: `slot n` addresses `[fp + n*8]`, bound by frame lowering.
pub struct Operand {
pub:
	kind   OperandKind
	reg    Reg
	imm    i64
	base   Reg
	disp   int
	symbol string
	slot   int
}

// slot_operand creates a stack slot operand.
pub fn slot_operand(slot int) Operand {
	return Operand{kind: .slot, slot: slot}
}

// reg_operand creates a register operand.
pub fn reg_operand(r Reg) Operand {
	return Operand{kind: .reg, reg: r}
}

// imm_operand creates an immediate operand.
pub fn imm_operand(v i64) Operand {
	return Operand{kind: .imm, imm: v}
}

// mem_operand creates a base plus displacement operand.
pub fn mem_operand(base Reg, disp int) Operand {
	return Operand{kind: .mem, base: base, disp: disp}
}

// sym_operand creates a symbol operand.
pub fn sym_operand(name string) Operand {
	return Operand{kind: .symbol, symbol: name}
}

// MachineInstr is one machine instruction. Jump and call targets are
// block ids and symbol names; data operands live in srcs. The destination
// is an operand (register or stack slot) so spilled definitions need no
// extra moves; instructions without a result leave has_dst false.
pub struct MachineInstr {
pub mut:
	op      MachineOp
	cond    Cond
	dst     Operand
	has_dst bool
	srcs    []Operand
	target  int
	symbol  string
}

// MachineBlock is one machine basic block.
pub struct MachineBlock {
pub mut:
	id     int
	name   string
	instrs []MachineInstr
}

// MachineFunc is one lowered function with its entry moves. After register
// allocation params holds the (physical or slot) locations of the
// incoming arguments, mirroring the entry moves.
pub struct MachineFunc {
pub mut:
	name   string
	params []Operand
	blocks []MachineBlock
	stack_slots int
}

// MachineModule is one lowered module.
pub struct MachineModule {
pub mut:
	triple string
	funcs  []MachineFunc
}

// reg_to_text renders one register.
fn reg_to_text(r Reg) string {
	if r.virt == frame_ptr_vreg {
		return 'fp'
	}
	if r.is_phys() {
		return r.phys.name()
	}
	return '%v${r.virt}'
}

// operand_to_text renders one operand.
fn operand_to_text(o Operand) string {
	return match o.kind {
		.reg { reg_to_text(o.reg) }
		.imm { '${o.imm}' }
		.mem { '[${reg_to_text(o.base)}+${o.disp}]' }
		.symbol { '$${o.symbol}' }
		.slot { '[fp+${o.slot * 8}]' }
	}
}

// instr_to_text renders one machine instruction.
fn instr_to_text(i MachineInstr) string {
	mut s := ''
	if i.has_dst {
		s += '${operand_to_text(i.dst)} = '
	}
	s += '${i.op}'
	if i.op == .jcc {
		s += ' ${cond_name(i.cond)}, @b${i.target}'
		return s
	}
	if i.op == .jmp {
		s += ' @b${i.target}'
		return s
	}
	if i.op == .call {
		s += ' $${i.symbol}'
		return s
	}
	for n, src in i.srcs {
		if n == 0 {
			s += ' '
		} else {
			s += ', '
		}
		s += operand_to_text(src)
	}
	return s
}

// mach_to_text renders a machine module for dumps and golden tests.
pub fn mach_to_text(m &MachineModule) string {
	mut out := 'machine ${m.triple}\n'
	for f in m.funcs {
		out += 'func $${f.name} :\n'
		for b in f.blocks {
			out += '@b${b.id} :\n'
			for ins in b.instrs {
				out += '  ${instr_to_text(ins)}\n'
			}
		}
	}
	return out
}
