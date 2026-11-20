module main

// Property-style fuzzing for the vendored IR text format: generate many small
// well-formed modules, print them, parse them back, and require byte-identical
// output plus a clean verifier. Any parser/printer drift breaks this.

import vssa.ssa
import vssa.optimize

struct FRng {
mut:
	seed u64
}

fn (mut r FRng) pick(n int) int {
	r.seed = r.seed * 6364136223846793005 + 1442695040888963407
	return int((r.seed >> 33) % u64(n))
}

fn random_module(seed int) &ssa.Module {
	mut r := FRng{ seed: u64(seed) * 2654435761 + 1 }
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	fid := m.new_function('f${seed}', i32_t)
	arg := m.add_value(.argument, i32_t, 'a', 0)
	m.func_add_param(fid, arg)
	block := m.add_block(fid, 'entry')

	mut vals := [arg]
	count := 2 + r.pick(6)
	for _ in 0 .. count {
		ops := [ssa.OpCode.add, ssa.OpCode.sub, ssa.OpCode.mul]
		op := ops[r.pick(ops.len)]
		c := m.get_or_add_const(i32_t, '${1 + r.pick(9)}')
		lhs := vals[r.pick(vals.len)]
		vals << m.add_instr(op, block, i32_t, [lhs, c])
	}
	m.add_instr(.ret, block, i32_t, [vals[vals.len - 1]])
	return m
}

fn test_fuzz_ir_text_roundtrip() {
	for seed in 0 .. 60 {
		m := random_module(seed)
		text := ssa.module_to_text(m)!
		mut m2 := ssa.module_from_text(text)!
		assert ssa.module_to_text(m2)! == text, 'round trip unstable for seed ${seed}'
		assert optimize.verify(m2).len == 0, 'verify failed for seed ${seed}'
	}
}
