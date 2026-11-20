module mach

import target

// Interval is one virtual register's live range in flattened instruction
// order, plus a coalescing hint from a dominating copy.
struct Interval {
	vreg  int
	start int
	end   int
	hint  int = -1
}

// Active is one live interval holding a pool register.
struct Active {
	end_ int
	reg  int
	vreg int
}

// reg_pool returns the allocatable caller-saved registers for a target.
// The return register (rax/x0) stays out of the pool so fixed
// call/return sequences can never collide with allocated values.
fn reg_pool(t target.Triple) ![]target.PhysReg {
	if t.arch == .amd64 {
		return [
			target.PhysReg{ arch: .amd64, index: 1 },
			target.PhysReg{ arch: .amd64, index: 2 },
			target.PhysReg{ arch: .amd64, index: 6 },
			target.PhysReg{ arch: .amd64, index: 7 },
			target.PhysReg{ arch: .amd64, index: 8 },
			target.PhysReg{ arch: .amd64, index: 9 },
			target.PhysReg{ arch: .amd64, index: 10 },
			target.PhysReg{ arch: .amd64, index: 11 },
		]
	}
	if t.arch == .arm64 {
		mut out := []target.PhysReg{}
		for i in 1 .. 16 {
			out << target.PhysReg{ arch: .arm64, index: i }
		}
		return out
	}
	return error('vir: no register pool for ${t.arch}')
}

// is_vreg_operand reports whether an operand names an allocatable virtual.
fn is_vreg_operand(o Operand) bool {
	return o.kind == .reg && !o.reg.is_phys() && o.reg.virt >= 0
}

// extend_intervals_for_loops widens a vreg's live range when its last use can
// reach a back-edge. Flat instruction order ends the interval at the last use,
// but a loop re-enters the block containing that use, so the value stays live
// through the loop body and its register must not be reused there.
fn extend_intervals_for_loops(f &MachineFunc, mut ends map[int]int, use_block map[int]int) {
	mut bstart := map[int]int{}
	mut bend := map[int]int{}
	mut pos := 0
	for b in f.blocks {
		bstart[b.id] = pos
		pos += b.instrs.len
		bend[b.id] = pos - 1
	}

	mut succ := map[int][]int{}
	for i, b in f.blocks {
		mut s := []int{}
		for ins in b.instrs {
			if (ins.op == .jmp || ins.op == .jcc) && ins.target in bstart {
				s << ins.target
			}
		}
		if b.instrs.len > 0 {
			last := b.instrs[b.instrs.len - 1]
			if last.op != .jmp && last.op != .ret && i + 1 < f.blocks.len {
				s << f.blocks[i + 1].id
			}
		}
		succ[b.id] = s
	}

	for v, blk in use_block {
		base := bstart[blk]
		mut seen := map[int]bool{}
		mut queue := [blk]
		mut has_back := false
		mut max_end := ends[v]
		for queue.len > 0 {
			cur := queue.pop()
			if seen[cur] {
				continue
			}
			seen[cur] = true
			if bend[cur] > max_end {
				max_end = bend[cur]
			}
			for nxt in succ[cur] {
				if bstart[nxt] <= base {
					has_back = true
				}
				queue << nxt
			}
		}
		if has_back {
			ends[v] = max_end
		}
	}
}

// collect_intervals computes live ranges and call positions in flattened
// block order.
fn collect_intervals(f &MachineFunc) ([]Interval, []int) {
	mut starts := map[int]int{}
	mut ends := map[int]int{}
	mut hints := map[int]int{}
	mut use_block := map[int]int{}
	mut calls := []int{}
	mut pos := 0
	for b in f.blocks {
		for ins in b.instrs {
			if ins.has_dst && ins.dst.kind == .reg && !ins.dst.reg.is_phys()
				&& ins.dst.reg.virt >= 0 {
				v := ins.dst.reg.virt
				if v !in starts {
					starts[v] = pos
				}
				ends[v] = pos
				if ins.op == .mov && ins.srcs.len == 1 && is_vreg_operand(ins.srcs[0])
					&& v !in hints {
					hints[v] = ins.srcs[0].reg.virt
				}
			}
			for s in ins.srcs {
				if is_vreg_operand(s) {
					v := s.reg.virt
					if v !in starts {
						starts[v] = pos
					}
					ends[v] = pos
					use_block[v] = b.id
				}
				if s.kind == .mem && !s.base.is_phys() && s.base.virt >= 0 {
					v := s.base.virt
					if v !in starts {
						starts[v] = pos
					}
					ends[v] = pos
				}
			}
			if ins.op == .call {
				calls << pos
			}
			pos++
		}
	}
	extend_intervals_for_loops(f, mut ends, use_block)
	mut intervals := []Interval{}
	for v, s in starts {
		h := hints[v] or { -1 }
		intervals << Interval{
			vreg:  v
			start: s
			end:   ends[v]
			hint:  h
		}
	}
	sort_intervals(mut intervals)
	return intervals, calls
}

// sort_intervals orders intervals by start position.
fn sort_intervals(mut xs []Interval) {
	for i in 1 .. xs.len {
		key := xs[i]
		mut j := i - 1
		for j >= 0 && xs[j].start > key.start {
			xs[j + 1] = xs[j]
			j--
		}
		xs[j + 1] = key
	}
}

// crosses_call reports whether an interval strictly contains a call.
// Values defined or last used exactly at the call are safe in registers:
// arguments are consumed before the clobber, results produced after it.
fn crosses_call(iv Interval, calls []int) bool {
	for c in calls {
		if iv.start < c && c < iv.end {
			return true
		}
	}
	return false
}

// allocate runs a linear scan over one function: intervals crossing calls
// spill, the rest take pool registers with copy-coalescing hints, and the
// leftovers spill. It returns the register or slot per vreg.
fn allocate_func(f &MachineFunc, pool []target.PhysReg) (map[int]Reg, map[int]int, int) {
	intervals, calls := collect_intervals(f)
	mut loc_reg := map[int]Reg{}
	mut loc_slot := map[int]int{}
	mut slots := 0
	mut active := []Active{}
	for iv in intervals {
		mut still := []Active{}
		for a in active {
			if a.end_ >= iv.start {
				still << a
			}
		}
		active = still.clone()
		if crosses_call(iv, calls) {
			loc_slot[iv.vreg] = slots
			slots++
			continue
		}
		mut used := map[int]bool{}
		for a in active {
			used[a.reg] = true
		}
		mut assigned := -1
		if iv.hint >= 0 && iv.hint in loc_reg {
			hi := reg_pool_index(pool, loc_reg[iv.hint])
			if hi >= 0 && hi !in used {
				assigned = hi
			}
		}
		if assigned < 0 {
			for i in 0 .. pool.len {
				if i !in used {
					assigned = i
					break
				}
			}
		}
		if assigned < 0 {
			mut best := -1
			mut best_end := iv.end
			for n, a in active {
				if a.end_ > best_end {
					best = n
					best_end = a.end_
				}
			}
			if best < 0 {
				loc_slot[iv.vreg] = slots
				slots++
				continue
			}
			loc_slot[active[best].vreg] = slots
			slots++
			assigned = active[best].reg
			active.delete(best)
		}
		loc_reg[iv.vreg] = preg(pool[assigned])
		active << Active{
			end_: iv.end
			reg:  assigned
			vreg: iv.vreg
		}
	}
	return loc_reg, loc_slot, slots
}

// reg_pool_index finds a physical register's pool index, or -1.
fn reg_pool_index(pool []target.PhysReg, r Reg) int {
	if !r.is_phys() {
		return -1
	}
	for i, p in pool {
		if p.arch == r.phys.arch && p.index == r.phys.index && p.is_float == r.phys.is_float {
			return i
		}
	}
	return -1
}

// rewrite_func replaces every virtual register with its allocation.
fn rewrite_func(mut f MachineFunc, loc_reg map[int]Reg, loc_slot map[int]int) ! {
	for bi in 0 .. f.blocks.len {
		for ii in 0 .. f.blocks[bi].instrs.len {
			mut ins := f.blocks[bi].instrs[ii]
			if ins.has_dst {
				ins.dst = rewrite_operand(ins.dst, loc_reg, loc_slot)!
			}
			for si in 0 .. ins.srcs.len {
				ins.srcs[si] = rewrite_operand(ins.srcs[si], loc_reg, loc_slot)!
			}
			f.blocks[bi].instrs[ii] = ins
		}
	}
	for pi in 0 .. f.params.len {
		f.params[pi] = rewrite_operand(f.params[pi], loc_reg, loc_slot)!
	}
}

// rewrite_operand maps one operand through the allocation.
fn rewrite_operand(o Operand, loc_reg map[int]Reg, loc_slot map[int]int) !Operand {
	if o.kind == .reg && !o.reg.is_phys() && o.reg.virt >= 0 {
		if r := loc_reg[o.reg.virt] {
			return reg_operand(r)
		}
		if s := loc_slot[o.reg.virt] {
			return slot_operand(s)
		}
		return error('vir: unallocated virtual register %v${o.reg.virt}')
	}
	if o.kind == .mem && !o.base.is_phys() && o.base.virt >= 0 {
		if r := loc_reg[o.base.virt] {
			return mem_operand(r, o.disp)
		}
		if s := loc_slot[o.base.virt] {
			return mem_operand(vreg(frame_ptr_vreg), o.disp - (s * 8 + 8))
		}
		return error('vir: unallocated virtual base %v${o.base.virt}')
	}
	return o
}

// allocate runs the linear-scan allocator over a module. Afterwards no
// virtual register remains: every value lives in a register or a slot.
pub fn allocate(mut m MachineModule) ! {
	t := target.parse_triple(m.triple)!
	pool := reg_pool(t)!
	for fi in 0 .. m.funcs.len {
		mut f := m.funcs[fi]
		loc_reg, loc_slot, slots := allocate_func(&f, pool)
		rewrite_func(mut f, loc_reg, loc_slot)!
		f.stack_slots = slots
		m.funcs[fi] = f
	}
}

// assert_no_vregs reports an error naming the first virtual register left
// in a module. M4 relies on this invariant.
pub fn assert_no_vregs(m &MachineModule) ! {
	for f in m.funcs {
		for b in f.blocks {
			for ins in b.instrs {
				if ins.has_dst && is_vreg_operand(ins.dst) {
					return error('vir: vreg %v${ins.dst.reg.virt} survived allocation')
				}
				for s in ins.srcs {
					if is_vreg_operand(s) {
						return error('vir: vreg %v${s.reg.virt} survived allocation')
					}
					if s.kind == .mem && !s.base.is_phys() && s.base.virt >= 0 {
						return error('vir: vreg base %v${s.base.virt} survived allocation')
					}
				}
			}
		}
	}
}
