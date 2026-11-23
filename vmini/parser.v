module vmini

// Parser for the V-subset. It reuses the cminus AST and code generator, so a
// V program lowers through exactly the same SSA pipeline as a C-minus one.
// `exit(expr)` is treated as a return of `expr`, matching how a V main sets
// its process exit code.

import cminus

pub struct Parser {
mut:
	toks []Token
	pos  int
}

pub fn parse(src string) ![]cminus.Func {
	toks := lex(src)!
	mut p := Parser{ toks: toks }
	mut funcs := []cminus.Func{}
	for p.peek().kind != .eof {
		funcs << p.parse_func()!
	}
	if funcs.len == 0 {
		return error('vmini: no functions')
	}
	return funcs
}

fn (mut p Parser) peek() Token {
	return p.toks[p.pos]
}

fn (mut p Parser) advance() Token {
	t := p.toks[p.pos]
	p.pos++
	return t
}

fn (mut p Parser) accept(k TokKind) bool {
	if p.peek().kind == k {
		p.pos++
		return true
	}
	return false
}

fn (mut p Parser) expect(k TokKind) !Token {
	t := p.peek()
	if t.kind != k {
		return error('vmini: line ${t.line}: expected ${k}, got ${t.kind}')
	}
	p.pos++
	return t
}

fn (mut p Parser) semi() {
	p.accept(.semi)
}

fn (mut p Parser) parse_func() !cminus.Func {
	kw := p.expect(.kw_fn)!
	name := p.expect(.ident)!.text
	_ = p.expect(.lparen)!
	mut params := []string{}
	if p.peek().kind != .rparen {
		for {
			pname := p.expect(.ident)!.text
			_ = p.expect(.kw_int)! // V parameter syntax is `name int`
			params << pname
			if !p.accept(.comma) {
				break
			}
		}
	}
	_ = p.expect(.rparen)!
	p.accept(.kw_int) // optional int return type
	body := p.parse_block()!
	return cminus.Func{ name: name, params: params, body: body, line: kw.line }
}

fn (mut p Parser) parse_block() ![]cminus.Stmt {
	_ = p.expect(.lbrace)!
	mut out := []cminus.Stmt{}
	for p.peek().kind != .rbrace {
		if p.peek().kind == .eof {
			return error('vmini: unterminated block')
		}
		out << p.parse_stmt()!
	}
	_ = p.expect(.rbrace)!
	return out
}

// parse_stmt returns a slice because `for` lowers to an init plus a loop.
fn (mut p Parser) parse_stmt() ![]cminus.Stmt {
	if p.peek().kind == .lbrace {
		line := p.peek().line
		return [cminus.Stmt{ kind: .block, body: p.parse_block()!, line: line }]
	}
	match p.peek().kind {
		.kw_return {
			t := p.advance()
			e := p.parse_expr()!
			p.semi()
			return [cminus.Stmt{ kind: .ret, expr: e, line: t.line }]
		}
		.kw_exit {
			t := p.advance()
			_ = p.expect(.lparen)!
			e := p.parse_expr()!
			_ = p.expect(.rparen)!
			p.semi()
			return [cminus.Stmt{ kind: .ret, expr: e, line: t.line }]
		}
		.kw_if {
			t := p.advance()
			c := p.parse_expr()!
			then_body := p.parse_block()!
			mut else_body := []cminus.Stmt{}
			if p.accept(.kw_else) {
				if p.peek().kind == .kw_if {
					else_body << p.parse_stmt()!
				} else {
					else_body = p.parse_block()!
				}
			}
			return [cminus.Stmt{ kind: .if_, cond: c, then_body: then_body, else_body: else_body, line: t.line }]
		}
		.kw_for {
			t := p.advance()
			name := p.expect(.ident)!.text
			_ = p.expect(.kw_in)!
			lo := p.parse_additive()!
			_ = p.expect(.range)!
			hi := p.parse_expr()!
			mut body := p.parse_block()!
			one := &cminus.Expr{ kind: .int_lit, int_val: 1, line: t.line }
			body << cminus.Stmt{
				kind: .assign
				name: name
				line: t.line
				expr: &cminus.Expr{
					kind: .binary
					op:   cminus.TokKind.plus
					lhs:  &cminus.Expr{ kind: .var_ref, name: name, line: t.line }
					rhs:  one
					line: t.line
				}
			}
			cond := &cminus.Expr{
				kind: .binary
				op:   cminus.TokKind.lt
				lhs:  &cminus.Expr{ kind: .var_ref, name: name, line: t.line }
				rhs:  hi
				line: t.line
			}
			return [
				cminus.Stmt{ kind: .decl, name: name, init: lo, line: t.line },
				cminus.Stmt{ kind: .while_, cond: cond, body: body, line: t.line },
			]
		}
		.semi {
			p.advance()
			return []
		}
		else {}
	}

	p.accept(.kw_mut) // `mut` is only a declaration hint for v1
	if p.peek().kind == .ident && p.toks[p.pos + 1].kind == .coloneq {
		line := p.peek().line
		name := p.advance().text
		p.advance()
		e := p.parse_expr()!
		p.semi()
		return [cminus.Stmt{ kind: .decl, name: name, init: e, line: line }]
	}
	if p.peek().kind == .ident && p.toks[p.pos + 1].kind == .assign {
		line := p.peek().line
		name := p.advance().text
		p.advance()
		e := p.parse_expr()!
		p.semi()
		return [cminus.Stmt{ kind: .assign, name: name, expr: e, line: line }]
	}
	line := p.peek().line
	e := p.parse_expr()!
	p.semi()
	return [cminus.Stmt{ kind: .expr_stmt, expr: e, line: line }]
}

fn (mut p Parser) parse_expr() !&cminus.Expr {
	return p.parse_equality()
}

fn (mut p Parser) parse_equality() !&cminus.Expr {
	mut lhs := p.parse_relational()!
	for p.peek().kind == .eqeq || p.peek().kind == .ne {
		t := p.advance()
		op := to_c_op(t.kind)
		rhs := p.parse_relational()!
		lhs = &cminus.Expr{ kind: .binary, op: op, lhs: lhs, rhs: rhs, line: t.line }
	}
	return lhs
}

fn (mut p Parser) parse_relational() !&cminus.Expr {
	mut lhs := p.parse_additive()!
	k := p.peek().kind
	if k == .lt || k == .gt || k == .le || k == .ge {
		t := p.advance()
		op := to_c_op(t.kind)
		rhs := p.parse_additive()!
		lhs = &cminus.Expr{ kind: .binary, op: op, lhs: lhs, rhs: rhs, line: t.line }
	}
	return lhs
}

fn (mut p Parser) parse_additive() !&cminus.Expr {
	mut lhs := p.parse_multiplicative()!
	for p.peek().kind == .plus || p.peek().kind == .minus {
		t := p.advance()
		op := to_c_op(t.kind)
		rhs := p.parse_multiplicative()!
		lhs = &cminus.Expr{ kind: .binary, op: op, lhs: lhs, rhs: rhs, line: t.line }
	}
	return lhs
}

fn (mut p Parser) parse_multiplicative() !&cminus.Expr {
	mut lhs := p.parse_unary()!
	for p.peek().kind == .star || p.peek().kind == .slash || p.peek().kind == .percent {
		t := p.advance()
		op := to_c_op(t.kind)
		rhs := p.parse_unary()!
		lhs = &cminus.Expr{ kind: .binary, op: op, lhs: lhs, rhs: rhs, line: t.line }
	}
	return lhs
}

fn (mut p Parser) parse_unary() !&cminus.Expr {
	if p.peek().kind == .minus {
		t := p.advance()
		e := p.parse_unary()!
		return &cminus.Expr{ kind: .neg, rhs: e, line: t.line }
	}
	return p.parse_primary()
}

fn (mut p Parser) parse_primary() !&cminus.Expr {
	t := p.peek()
	match t.kind {
		.number {
			p.advance()
			return &cminus.Expr{ kind: .int_lit, int_val: t.int_val, line: t.line }
		}
		.lparen {
			p.advance()
			e := p.parse_expr()!
			_ = p.expect(.rparen)!
			return e
		}
		.ident {
			p.advance()
			if p.peek().kind == .lparen {
				p.advance()
				mut args := []&cminus.Expr{}
				if p.peek().kind != .rparen {
					for {
						args << p.parse_expr()!
						if !p.accept(.comma) {
							break
						}
					}
				}
				_ = p.expect(.rparen)!
				return &cminus.Expr{ kind: .call, name: t.text, args: args, line: t.line }
			}
			return &cminus.Expr{ kind: .var_ref, name: t.text, line: t.line }
		}
		else {
			return error('vmini: line ${t.line}: expected an expression, got ${t.kind}')
		}
	}
}

fn to_c_op(k TokKind) cminus.TokKind {
	return match k {
		.plus { cminus.TokKind.plus }
		.minus { cminus.TokKind.minus }
		.star { cminus.TokKind.star }
		.slash { cminus.TokKind.slash }
		.percent { cminus.TokKind.percent }
		.eqeq { cminus.TokKind.eqeq }
		.ne { cminus.TokKind.ne }
		.lt { cminus.TokKind.lt }
		.gt { cminus.TokKind.gt }
		.le { cminus.TokKind.le }
		.ge { cminus.TokKind.ge }
		else { cminus.TokKind.plus }
	}
}
