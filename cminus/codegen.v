module cminus

import vssa.ssa

// Codegen lowers a C-minus AST into a `ssa.Module`. Locals become allocas;
// the vir optimizer's mem2reg pass promotes them to registers and eliminates
// the phis at control-flow merges before instruction selection.

struct Codegen {
mut:
	m                 &ssa.Module
	i32_t             ssa.TypeID
	ptr_i32           ssa.TypeID
	void_t            ssa.TypeID
	cur               ssa.BlockID
	terminated        bool
	current_func_name string
	vars              map[string]ssa.ValueID
	func_ids          map[string]int
	next_ext          int
	cur_line          int
	lines             map[int]int
}

// generate builds a module from parsed C-minus functions.
pub fn generate(funcs []Func) !&ssa.Module {
	m, _ := generate_with_lines(funcs)!
	return m
}

// generate_with_lines builds a module plus a line table mapping each emitted
// instruction value id to its source line. The optimizer may add or remove
// instructions later, so consumers must tolerate missing keys (line 0).
pub fn generate_with_lines(funcs []Func) !(&ssa.Module, map[int]int) {
	mut m := ssa.Module.new()
	i32_t := m.type_store.get_int(32)
	mut cg := Codegen{
		m:        m
		i32_t:    i32_t
		ptr_i32:  m.type_store.get_ptr(i32_t)
		void_t:   ssa.TypeID(0)
		vars:     map[string]ssa.ValueID{}
		func_ids: map[string]int{}
		next_ext: funcs.len
		lines:    map[int]int{}
	}

	// Declare all functions first so calls can resolve to a func_ref.
	for f in funcs {
		cg.func_ids[f.name] = m.new_function(f.name, i32_t)
	}
	for f in funcs {
		cg.emit_func(f)!
	}
	return m, cg.lines
}

// add emits one instruction and records its source line for the DWARF line
// table. Instructions from implicit code (epilogue returns) keep line 0 and
// are skipped by the line emitter.
fn (mut cg Codegen) add(op ssa.OpCode, block ssa.BlockID, typ ssa.TypeID, operands []ssa.ValueID) ssa.ValueID {
	vid := cg.m.add_instr(op, block, typ, operands)
	if cg.cur_line > 0 {
		cg.lines[int(vid)] = cg.cur_line
	}
	return vid
}

fn (mut cg Codegen) zero() ssa.ValueID {
	return cg.m.get_or_add_const(cg.i32_t, '0')
}

fn (mut cg Codegen) const_val(v i64) ssa.ValueID {
	return cg.m.get_or_add_const(cg.i32_t, '${v}')
}

fn (mut cg Codegen) new_block(name string) ssa.BlockID {
	// The function id is the one currently being emitted; recover it from the
	// block's owner via the last function created by new_function.
	fid := cg.func_ids[cg.current_func_name]
	return cg.m.add_block(fid, name)
}

fn (mut cg Codegen) emit_func(f Func) ! {
	cg.vars = map[string]ssa.ValueID{}
	cg.current_func_name = f.name
	cg.cur_line = f.line
	fid := cg.func_ids[f.name]
	entry := cg.m.add_block(fid, 'entry')
	cg.cur = entry
	cg.terminated = false

	zero := cg.zero()
	for i, pname in f.params {
		arg := cg.m.add_value(.argument, cg.i32_t, pname, i)
		cg.m.func_add_param(fid, arg)
		slot := cg.add(.alloca, cg.cur, cg.ptr_i32, [])
		_ = cg.add(.store, cg.cur, cg.void_t, [arg, slot])
		cg.vars[pname] = slot
	}
	cg.emit_stmts(f.body)!
	if !cg.terminated {
		cg.add(.ret, cg.cur, cg.i32_t, [zero])
		cg.terminated = true
	}
}

fn (mut cg Codegen) emit_stmts(stmts []Stmt) ! {
	for s in stmts {
		if cg.terminated {
			// Unreachable statement: start a fresh block so later code still
			// has somewhere to go if the branch was folded away later.
			cg.cur = cg.new_block('unreachable')
			cg.terminated = false
		}
		cg.emit_stmt(s)!
	}
}

fn (mut cg Codegen) emit_stmt(s Stmt) ! {
	cg.cur_line = s.line
	match s.kind {
		.block {
			cg.emit_stmts(s.body)!
		}
		.decl {
			slot := cg.add(.alloca, cg.cur, cg.ptr_i32, [])
			mut v := cg.zero()
			if init := s.init {
				v = cg.emit_expr(init)!
			}
			_ = cg.add(.store, cg.cur, cg.void_t, [v, slot])
			cg.vars[s.name] = slot
		}
		.assign {
			mut v := cg.zero()
			if e := s.expr {
				v = cg.emit_expr(e)!
			}
			if slot := cg.vars[s.name] {
				_ = cg.add(.store, cg.cur, cg.void_t, [v, slot])
			} else {
				return error('cminus: assignment to unknown variable ${s.name}')
			}
		}
		.ret {
			mut v := cg.zero()
			if e := s.expr {
				v = cg.emit_expr(e)!
			}
			cg.add(.ret, cg.cur, cg.i32_t, [v])
			cg.terminated = true
		}
		.expr_stmt {
			if e := s.expr {
				_ = cg.emit_expr(e)!
			}
		}
		.if_ {
			cg.emit_if(s)!
		}
		.while_ {
			cg.emit_while(s)!
		}
	}
}

fn (mut cg Codegen) emit_if(s Stmt) ! {
	cg.cur_line = s.line
	cond := cg.emit_expr(s.cond or { return error('cminus: if without condition') })!
	then_b := cg.new_block('then')
	else_b := cg.new_block('else')
	merge_b := cg.new_block('merge')
	cg.add(.br, cg.cur, cg.void_t, [cond, ssa.ValueID(then_b), ssa.ValueID(else_b)])
	cg.terminated = true

	cg.cur = then_b
	cg.terminated = false
	cg.emit_stmts(s.then_body)!
	if !cg.terminated {
		cg.add(.jmp, cg.cur, cg.void_t, [ssa.ValueID(merge_b)])
		cg.terminated = true
	}

	cg.cur = else_b
	cg.terminated = false
	cg.emit_stmts(s.else_body)!
	if !cg.terminated {
		cg.add(.jmp, cg.cur, cg.void_t, [ssa.ValueID(merge_b)])
		cg.terminated = true
	}

	cg.cur = merge_b
	cg.terminated = false
}

fn (mut cg Codegen) emit_while(s Stmt) ! {
	cg.cur_line = s.line
	cond_b := cg.new_block('loop_cond')
	body_b := cg.new_block('loop_body')
	after_b := cg.new_block('loop_after')
	cg.add(.jmp, cg.cur, cg.void_t, [ssa.ValueID(cond_b)])
	cg.terminated = true

	cg.cur = cond_b
	cg.terminated = false
	cond := cg.emit_expr(s.cond or { return error('cminus: while without condition') })!
	cg.add(.br, cg.cur, cg.void_t, [cond, ssa.ValueID(body_b), ssa.ValueID(after_b)])
	cg.terminated = true

	cg.cur = body_b
	cg.terminated = false
	cg.emit_stmts(s.body)!
	if !cg.terminated {
		cg.add(.jmp, cg.cur, cg.void_t, [ssa.ValueID(cond_b)])
		cg.terminated = true
	}

	cg.cur = after_b
	cg.terminated = false
}

fn (mut cg Codegen) emit_expr(e &Expr) !ssa.ValueID {
	prev := cg.cur_line
	cg.cur_line = e.line
	defer {
		cg.cur_line = prev
	}
	match e.kind {
		.int_lit {
			return cg.const_val(e.int_val)
		}
		.var_ref {
			if slot := cg.vars[e.name] {
				return cg.add(.load, cg.cur, cg.i32_t, [slot])
			}
			return error('cminus: unknown variable ${e.name}')
		}
		.neg {
			rhs := cg.emit_expr(e.rhs or { return error('cminus: bad neg') })!
			return cg.add(.sub, cg.cur, cg.i32_t, [cg.zero(), rhs])
		}
		.binary {
			op := cg.binop(e.op)!
			lhs := cg.emit_expr(e.lhs or { return error('cminus: bad lhs') })!
			rhs := cg.emit_expr(e.rhs or { return error('cminus: bad rhs') })!
			return cg.add(op, cg.cur, cg.i32_t, [lhs, rhs])
		}
		.call {
			mut args := []ssa.ValueID{}
			for a in e.args {
				args << cg.emit_expr(a)!
			}
			fid := cg.func_ids[e.name] or { cg.next_ext }
			ref := cg.m.add_value(.func_ref, cg.i32_t, e.name, fid)
			mut operands := []ssa.ValueID{}
			operands << ref
			operands << args
			return cg.add(.call, cg.cur, cg.i32_t, operands)
		}
	}
}

fn (mut cg Codegen) binop(k TokKind) !ssa.OpCode {
	return match k {
		.plus { ssa.OpCode.add }
		.minus { ssa.OpCode.sub }
		.star { ssa.OpCode.mul }
		.slash { ssa.OpCode.sdiv }
		.percent { ssa.OpCode.srem }
		.eqeq { ssa.OpCode.eq }
		.ne { ssa.OpCode.ne }
		.lt { ssa.OpCode.lt }
		.gt { ssa.OpCode.gt }
		.le { ssa.OpCode.le }
		.ge { ssa.OpCode.ge }
		else { return error('cminus: unsupported binary operator') }
	}
}
