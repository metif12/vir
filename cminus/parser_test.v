module cminus

fn test_lex_subset() {
	toks := lex('int main() { return 1 + 2 >= 3; }')!
	assert toks[0].kind == .kw_int
	assert toks[1].kind == .ident && toks[1].text == 'main'
	assert toks[3].kind == .rparen
	assert toks[9].kind == .ge
	assert toks[toks.len - 1].kind == .eof
}

fn test_parse_locals_and_if() {
	funcs := parse('int main() { int x = 1; if (x > 0) { return x; } return 0; }')!
	assert funcs.len == 1
	assert funcs[0].name == 'main'
	assert funcs[0].params.len == 0
	assert funcs[0].body.len == 3
	assert funcs[0].body[0].kind == .decl
	assert funcs[0].body[1].kind == .if_
	assert funcs[0].body[2].kind == .ret
}

fn test_parse_params_and_while() {
	funcs := parse('int add(int a, int b) { int i = 0; while (i < a) { i = i + 1; } return b + i; }')!
	assert funcs.len == 1
	assert funcs[0].params == ['a', 'b']
	assert funcs[0].body.len == 3
	assert funcs[0].body[1].kind == .while_
}

fn test_parse_call() {
	funcs := parse('int main() { return add(1, 2); }')!
	ret := funcs[0].body[0]
	assert ret.expr or { panic('no expr') }.kind == .call
}
