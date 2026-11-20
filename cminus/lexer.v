module cminus

// A small lexer for the C-minus subset: integers, identifiers, the keywords
// int/return/if/else/while, arithmetic and comparison operators, and
// punctuation. Comments (// and /* */) and whitespace are skipped.

pub enum TokKind {
	eof
	ident
	number
	kw_int
	kw_return
	kw_if
	kw_else
	kw_while
	plus
	minus
	star
	slash
	percent
	lparen
	rparen
	lbrace
	rbrace
	semi
	comma
	assign
	eqeq
	ne
	lt
	gt
	le
	ge
}

pub struct Token {
pub:
	kind    TokKind
	text    string
	int_val i64
	line    int
}

fn is_letter(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

fn is_digit(c u8) bool {
	return c >= `0` && c <= `9`
}

fn is_alnum(c u8) bool {
	return is_letter(c) || is_digit(c)
}

// lex tokenizes src. A bad character returns an error with its line number.
pub fn lex(src string) ![]Token {
	mut toks := []Token{}
	mut i := 0
	mut line := 1
	b := src.bytes()
	for i < b.len {
		c := b[i]
		if c == `\n` {
			line++
			i++
			continue
		}
		if c == ` ` || c == `\t` || c == `\r` {
			i++
			continue
		}
		if c == `/` && i + 1 < b.len && b[i + 1] == `/` {
			for i < b.len && b[i] != `\n` {
				i++
			}
			continue
		}
		if c == `/` && i + 1 < b.len && b[i + 1] == `*` {
			i += 2
			for i + 1 < b.len && !(b[i] == `*` && b[i + 1] == `/`) {
				if b[i] == `\n` {
					line++
				}
				i++
			}
			if i + 1 >= b.len {
				return error('cminus: unterminated comment on line ${line}')
			}
			i += 2
			continue
		}
		start := i
		if is_letter(c) {
			for i < b.len && is_alnum(b[i]) {
				i++
			}
			word := src[start..i]
			kind := match word {
				'int' { TokKind.kw_int }
				'return' { TokKind.kw_return }
				'if' { TokKind.kw_if }
				'else' { TokKind.kw_else }
				'while' { TokKind.kw_while }
				else { TokKind.ident }
			}
			toks << Token{ kind: kind, text: word, line: line }
			continue
		}
		if is_digit(c) {
			for i < b.len && is_digit(b[i]) {
				i++
			}
			digits := src[start..i]
			toks << Token{
				kind:    .number
				text:    digits
				int_val: digits.i64()
				line:    line
			}
			continue
		}
		// Two-character operators first.
		if i + 1 < b.len {
			pair := src[i..i + 2]
			match pair {
				'==' {
					toks << Token{ kind: .eqeq, text: pair, line: line }
					i += 2
					continue
				}
				'!=' {
					toks << Token{ kind: .ne, text: pair, line: line }
					i += 2
					continue
				}
				'<=' {
					toks << Token{ kind: .le, text: pair, line: line }
					i += 2
					continue
				}
				'>=' {
					toks << Token{ kind: .ge, text: pair, line: line }
					i += 2
					continue
				}
				else {}
			}
		}
		kind := match c {
			`+` { TokKind.plus }
			`-` { TokKind.minus }
			`*` { TokKind.star }
			`/` { TokKind.slash }
			`%` { TokKind.percent }
			`(` { TokKind.lparen }
			`)` { TokKind.rparen }
			`{` { TokKind.lbrace }
			`}` { TokKind.rbrace }
			`;` { TokKind.semi }
			`,` { TokKind.comma }
			`=` { TokKind.assign }
			`<` { TokKind.lt }
			`>` { TokKind.gt }
			else { return error('cminus: unexpected character `${c:c}` on line ${line}') }
		}
		toks << Token{ kind: kind, text: src[i..i + 1], line: line }
		i++
	}
	toks << Token{ kind: .eof, text: '', line: line }
	return toks
}
