module cminus

// Recursive-descent parser for the C-minus subset. The AST is intentionally
// small: enough for integer arithmetic, locals, if/else, while and calls.

pub enum ExprKind {
	int_lit
	var_ref
	binary
	call
	neg
}

pub struct Expr {
pub:
	kind    ExprKind
	int_val i64
	name    string
	op      TokKind
	lhs     ?&Expr
	rhs     ?&Expr
	args    []&Expr
}

pub enum StmtKind {
	decl
	assign
	ret
	if_
	while_
	block
	expr_stmt
}

pub struct Stmt {
pub:
	kind      StmtKind
	name      string
	init      ?&Expr
	expr      ?&Expr
	cond      ?&Expr
	then_body []Stmt
	else_body []Stmt
	body      []Stmt
}

pub struct Func {
pub:
	name   string
	params []string
	body   []Stmt
}

pub struct Parser {
mut:
	toks []Token
	pos  int
}

pub fn parse(src string) ![]Func {
	toks := lex(src)!
	mut p := Parser{ toks: toks }
	mut funcs := []Func{}
	for p.peek().kind != .eof {
		funcs << p.parse_func()!
	}
	if funcs.len == 0 {
		return error('cminus: no functions')
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
		return error('cminus: line ${t.line}: expected ${k}, got ${t.kind}')
	}
	p.pos++
	return t
}

fn (mut p Parser) parse_func() !Func {
	_ = p.expect(.kw_int)!
	name := p.expect(.ident)!.text
	_ = p.expect(.lparen)!
	mut params := []string{}
	if p.peek().kind != .rparen {
		for {
			_ = p.expect(.kw_int)!
			params << p.expect(.ident)!.text
			if !p.accept(.comma) {
				break
			}
		}
	}
	_ = p.expect(.rparen)!
	body := p.parse_block_stmts()!
	return Func{ name: name, params: params, body: body }
}

fn (mut p Parser) parse_block_stmts() ![]Stmt {
	_ = p.expect(.lbrace)!
	mut stmts := []Stmt{}
	for p.peek().kind != .rbrace {
		if p.peek().kind == .eof {
			return error('cminus: unterminated block')
		}
		stmts << p.parse_stmt()!
	}
	_ = p.expect(.rbrace)!
	return stmts
}

fn (mut p Parser) parse_stmt() !Stmt {
	if p.peek().kind == .lbrace {
		return Stmt{ kind: .block, body: p.parse_block_stmts()! }
	}
	match p.peek().kind {
		.kw_return {
			p.advance()
			e := p.parse_expr()!
			_ = p.expect(.semi)!
			return Stmt{ kind: .ret, expr: e }
		}
		.kw_if {
			p.advance()
			_ = p.expect(.lparen)!
			c := p.parse_expr()!
			_ = p.expect(.rparen)!
			then_s := p.parse_stmt()!
			mut else_s := []Stmt{}
			if p.accept(.kw_else) {
				else_s << p.parse_stmt()!
			}
			return Stmt{ kind: .if_, cond: c, then_body: [then_s], else_body: else_s }
		}
		.kw_while {
			p.advance()
			_ = p.expect(.lparen)!
			c := p.parse_expr()!
			_ = p.expect(.rparen)!
			body_s := p.parse_stmt()!
			return Stmt{ kind: .while_, cond: c, body: [body_s] }
		}
		.kw_int {
			p.advance()
			name := p.expect(.ident)!.text
			mut init := ?&Expr(none)
			if p.accept(.assign) {
				init = p.parse_expr()!
			}
			_ = p.expect(.semi)!
			return Stmt{ kind: .decl, name: name, init: init }
		}
		.semi {
			p.advance()
			return Stmt{ kind: .block, body: []Stmt{} }
		}
		else {}
	}
	if p.peek().kind == .ident && p.toks[p.pos + 1].kind == .assign {
		name := p.advance().text
		p.advance()
		e := p.parse_expr()!
		_ = p.expect(.semi)!
		return Stmt{ kind: .assign, name: name, expr: e }
	}
	e := p.parse_expr()!
	_ = p.expect(.semi)!
	return Stmt{ kind: .expr_stmt, expr: e }
}

fn (mut p Parser) parse_expr() !&Expr {
	return p.parse_equality()
}

fn (mut p Parser) parse_equality() !&Expr {
	mut lhs := p.parse_relational()!
	for p.peek().kind == .eqeq || p.peek().kind == .ne {
		op := p.advance().kind
		rhs := p.parse_relational()!
		lhs = &Expr{ kind: .binary, op: op, lhs: lhs, rhs: rhs }
	}
	return lhs
}

fn (mut p Parser) parse_relational() !&Expr {
	mut lhs := p.parse_additive()!
	k := p.peek().kind
	if k == .lt || k == .gt || k == .le || k == .ge {
		op := p.advance().kind
		rhs := p.parse_additive()!
		lhs = &Expr{ kind: .binary, op: op, lhs: lhs, rhs: rhs }
	}
	return lhs
}

fn (mut p Parser) parse_additive() !&Expr {
	mut lhs := p.parse_multiplicative()!
	for p.peek().kind == .plus || p.peek().kind == .minus {
		op := p.advance().kind
		rhs := p.parse_multiplicative()!
		lhs = &Expr{ kind: .binary, op: op, lhs: lhs, rhs: rhs }
	}
	return lhs
}

fn (mut p Parser) parse_multiplicative() !&Expr {
	mut lhs := p.parse_unary()!
	for p.peek().kind == .star || p.peek().kind == .slash || p.peek().kind == .percent {
		op := p.advance().kind
		rhs := p.parse_unary()!
		lhs = &Expr{ kind: .binary, op: op, lhs: lhs, rhs: rhs }
	}
	return lhs
}

fn (mut p Parser) parse_unary() !&Expr {
	if p.accept(.minus) {
		e := p.parse_unary()!
		return &Expr{ kind: .neg, rhs: e }
	}
	return p.parse_primary()
}

fn (mut p Parser) parse_primary() !&Expr {
	t := p.peek()
	match t.kind {
		.number {
			p.advance()
			return &Expr{ kind: .int_lit, int_val: t.int_val }
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
				mut args := []&Expr{}
				if p.peek().kind != .rparen {
					for {
						args << p.parse_expr()!
						if !p.accept(.comma) {
							break
						}
					}
				}
				_ = p.expect(.rparen)!
				return &Expr{ kind: .call, name: t.text, args: args }
			}
			return &Expr{ kind: .var_ref, name: t.text }
		}
		else {
			return error('cminus: line ${t.line}: expected an expression, got ${t.kind}')
		}
	}
}
