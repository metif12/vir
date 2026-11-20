module bitcode

// Binary IR format for vir (post-v1 "binary bitcode"). It encodes the SSA
// core used by vir's frontends: types, values, instructions, blocks and
// functions. Globals, inline-asm specs and the V-specific side tables are
// deliberately out of scope for v1 and are rejected on encode.

import vssa.ssa

const magic = [u8(0x56), u8(0x42), u8(0x43), u8(0x31)] // "VBC1"
const version = u16(1)

struct Reader {
	b []u8
mut:
	pos int
}

fn need(r &Reader, n int) ! {
	if r.pos + n > r.b.len {
		return error('bitcode: unexpected end of stream')
	}
}

fn (mut r Reader) u8() !u8 {
	need(r, 1)!
	v := r.b[r.pos]
	r.pos++
	return v
}

fn (mut r Reader) u16() !u16 {
	need(r, 2)!
	v := u16(r.b[r.pos]) | (u16(r.b[r.pos + 1]) << 8)
	r.pos += 2
	return v
}

fn (mut r Reader) u32() !u32 {
	need(r, 4)!
	mut v := u32(0)
	for i in 0 .. 4 {
		v |= u32(r.b[r.pos + i]) << (8 * i)
	}
	r.pos += 4
	return v
}

fn (mut r Reader) i32() !i32 {
	return i32(r.u32()!)
}

fn (mut r Reader) read_str() !string {
	n := r.u16()!
	need(r, int(n))!
	s := r.b[r.pos..r.pos + int(n)].bytestr()
	r.pos += int(n)
	return s
}

fn put_u8(mut b []u8, v u8) {
	b << v
}

fn put_u16(mut b []u8, v u16) {
	b << u8(v)
	b << u8(v >> 8)
}

fn put_u32(mut b []u8, v u32) {
	for i in 0 .. 4 {
		b << u8(v >> (8 * i))
	}
}

fn put_str(mut b []u8, s string) {
	put_u16(mut b, u16(s.len))
	b << s.bytes()
}

fn put_ids(mut b []u8, ids []int) {
	put_u32(mut b, u32(ids.len))
	for id in ids {
		put_u32(mut b, u32(id))
	}
}

fn read_ids(mut r Reader) ![]int {
	n := int(r.u32()!)
	if n > 1_000_000 {
		return error('bitcode: implausible id count')
	}
	mut out := []int{cap: n}
	for _ in 0 .. n {
		out << int(r.u32()!)
	}
	return out
}

fn encode_type(mut b []u8, t ssa.Type) {
	put_u8(mut b, u8(t.kind))
	put_u32(mut b, u32(t.width))
	put_u8(mut b, u8(if t.is_unsigned { 1 } else { 0 }))
	put_u32(mut b, u32(t.elem_type))
	put_u32(mut b, u32(t.len))
	put_ids(mut b, t.fields)
	put_u32(mut b, u32(t.field_names.len))
	for name in t.field_names {
		put_str(mut b, name)
	}
	put_ids(mut b, t.params)
	put_u32(mut b, u32(t.ret_type))
	mut flags := u8(0)
	if t.is_c_struct {
		flags |= 1
	}
	if t.is_union {
		flags |= 2
	}
	if t.is_packed {
		flags |= 4
	}
	put_u8(mut b, flags)
	put_u32(mut b, u32(t.alignment))
	put_u32(mut b, u32(t.size))
	put_ids(mut b, t.field_offsets)
}

fn decode_type(mut r Reader) !ssa.Type {
	kind := unsafe { ssa.TypeKind(r.u8()!) }
	width := int(r.u32()!)
	unsigned := r.u8()! != 0
	elem := ssa.TypeID(r.u32()!)
	len := int(r.u32()!)
	fields := read_ids(mut r)!
	nfields := int(r.u32()!)
	mut names := []string{cap: nfields}
	for _ in 0 .. nfields {
		names << r.read_str()!
	}
	params := read_ids(mut r)!
	ret := ssa.TypeID(r.u32()!)
	flags := r.u8()!
	align := int(r.u32()!)
	size := int(r.u32()!)
	offsets := read_ids(mut r)!
	return ssa.Type{
		kind:          kind
		width:         width
		is_unsigned:   unsigned
		elem_type:     elem
		len:           len
		fields:        fields
		field_names:   names
		params:        params
		ret_type:      ret
		is_c_struct:   (flags & 1) != 0
		is_union:      (flags & 2) != 0
		is_packed:     (flags & 4) != 0
		alignment:     align
		size:          size
		field_offsets: offsets
	}
}

// encode serializes a module into the v1 binary format.
pub fn encode(m &ssa.Module) ![]u8 {
	if m.globals.len > 0 {
		return error('bitcode: globals are not supported in v1')
	}
	if m.asm_specs.len > 0 {
		return error('bitcode: inline asm is not supported in v1')
	}
	mut b := []u8{}
	b << magic
	put_u16(mut b, version)
	put_u8(mut b, u8(m.target.ptr_size))
	put_u8(mut b, u8(if m.target.endian_little { 1 } else { 0 }))
	put_str(mut b, m.name)
	put_str(mut b, m.target.os)
	put_str(mut b, m.target.arch)
	put_u8(mut b, u8(if m.track_uses { 1 } else { 0 }))

	// Types: index 0 is always void and is reconstructed by Module.new().
	put_u32(mut b, u32(m.type_store.types.len - 1))
	for i in 1 .. m.type_store.types.len {
		encode_type(mut b, m.type_store.types[i])
	}

	put_u32(mut b, u32(m.values.len - 1))
	for i in 1 .. m.values.len {
		v := m.values[i]
		put_u8(mut b, u8(v.kind))
		put_u32(mut b, u32(v.typ))
		put_str(mut b, v.name)
		put_u32(mut b, u32(v.index))
	}

	// Map each instruction index to the value id that defines it.
	mut instr_value := map[int]int{}
	for v in m.values {
		if v.kind == .instruction {
			instr_value[v.index] = v.id
		}
	}
	put_u32(mut b, u32(m.instrs.len))
	for ii, ins in m.instrs {
		put_u32(mut b, u32(instr_value[ii]))
		put_u8(mut b, u8(ins.op))
		put_u32(mut b, u32(ins.typ))
		put_u32(mut b, u32(ins.block))
		put_ids(mut b, ins.operands)
		put_u8(mut b, u8(ins.atomic_ord))
		put_u8(mut b, u8(ins.inline))
		put_u32(mut b, u32(ins.asm_id))
	}

	put_u32(mut b, u32(m.blocks.len))
	for blk in m.blocks {
		put_u32(mut b, u32(blk.id))
		put_u32(mut b, u32(blk.val_id))
		put_str(mut b, blk.name)
		put_u32(mut b, u32(blk.parent))
		put_ids(mut b, blk.instrs)
	}

	put_u32(mut b, u32(m.funcs.len))
	for f in m.funcs {
		put_str(mut b, f.name)
		put_u32(mut b, u32(f.typ))
		mut block_ids := []int{cap: f.blocks.len}
		for id in f.blocks {
			block_ids << int(id)
		}
		mut param_ids := []int{cap: f.params.len}
		for id in f.params {
			param_ids << int(id)
		}
		put_ids(mut b, block_ids)
		put_ids(mut b, param_ids)
		mut flags := u8(0)
		if f.is_c_extern {
			flags |= 1
		}
		if f.is_variadic {
			flags |= 2
		}
		if f.is_prototype {
			flags |= 4
		}
		put_u8(mut b, flags)
		put_u8(mut b, u8(f.linkage))
		put_u8(mut b, u8(f.call_conv))
		put_u32(mut b, u32(f.variadic_start))
	}
	return b
}

// decode reconstructs a module from v1 binary IR. Features rejected by
// encode are rejected here too.
pub fn decode(bytes []u8) !&ssa.Module {
	mut r := Reader{ b: bytes }
	for c, expected in magic {
		if r.u8()! != expected {
			return error('bitcode: bad magic at byte ${c}')
		}
	}
	if r.u16()! != version {
		return error('bitcode: unsupported version')
	}
	ptr_size := int(r.u8()!)
	little := r.u8()! != 0
	name := r.read_str()!
	os := r.read_str()!
	arch := r.read_str()!
	track := r.u8()! != 0

	mut m := ssa.Module.new()
	m.name = name
	m.target = ssa.TargetData{
		ptr_size:      ptr_size
		endian_little: little
		os:            os
		arch:          arch
	}
	m.track_uses = track

	ntypes := int(r.u32()!)
	for _ in 0 .. ntypes {
		t := decode_type(mut r)!
		m.type_store.register(t)
	}
	rebuild_cache(mut m)

	// Read sections in stream order: values, instrs, blocks, funcs.
	nvalues := int(r.u32()!)
	mut vkinds := []ssa.ValueKind{cap: nvalues}
	mut vtyps := []ssa.TypeID{cap: nvalues}
	mut vnames := []string{cap: nvalues}
	mut vindexes := []int{cap: nvalues}
	for _ in 0 .. nvalues {
		vkinds << unsafe { ssa.ValueKind(r.u8()!) }
		vtyps << ssa.TypeID(r.u32()!)
		vnames << r.read_str()!
		vindexes << int(r.u32()!)
	}

	ninstrs := int(r.u32()!)
	mut ins_by_value := map[int]ssa.Instruction{}
	for _ in 0 .. ninstrs {
		value_id := int(r.u32()!)
		op := unsafe { ssa.OpCode(r.u8()!) }
		typ := ssa.TypeID(r.u32()!)
		block := ssa.BlockID(r.u32()!)
		ops := read_ids(mut r)!
		ord := unsafe { ssa.AtomicOrdering(r.u8()!) }
		inline := unsafe { ssa.InlineHint(r.u8()!) }
		asm_id := int(r.u32()!)
		mut operands := []ssa.ValueID{cap: ops.len}
		for id in ops {
			operands << ssa.ValueID(id)
		}
		ins_by_value[value_id] = ssa.Instruction{
			op:         op
			operands:   operands
			block:      block
			typ:        typ
			atomic_ord: ord
			inline:     inline
			asm_id:     asm_id
		}
	}

	nblocks := int(r.u32()!)
	mut bnames := []string{cap: nblocks}
	mut bparents := []int{cap: nblocks}
	for _ in 0 .. nblocks {
		_ = r.u32()! // id
		_ = r.u32()! // val_id
		bnames << r.read_str()!
		bparents << int(r.u32()!)
		_ = read_ids(mut r)! // instrs, rebuilt by add_instr
	}

	nfunctions := int(r.u32()!)
	mut fn_names := []string{cap: nfunctions}
	mut fn_rets := []ssa.TypeID{cap: nfunctions}
	mut fn_blocks := [][]int{}
	mut fn_params := [][]int{}
	mut fn_flags := []u8{}
	mut fn_link := []u8{}
	mut fn_conv := []u8{}
	mut fn_varstart := []int{}
	for _ in 0 .. nfunctions {
		fn_names << r.read_str()!
		fn_rets << ssa.TypeID(r.u32()!)
		fn_blocks << read_ids(mut r)!
		fn_params << read_ids(mut r)!
		fn_flags << r.u8()!
		fn_link << r.u8()!
		fn_conv << r.u8()!
		fn_varstart << int(r.u32()!)
	}

	// Construct in dependency order: functions, blocks, then values.
	for fi in 0 .. nfunctions {
		m.new_function(fn_names[fi], fn_rets[fi])
	}
	for bi in 0 .. nblocks {
		m.add_block(bparents[bi], bnames[bi])
	}
	for id in 1 .. nvalues + 1 {
		kind := vkinds[id - 1]
		if kind == .instruction {
			ins := ins_by_value[id]
			m.add_instr(ins.op, ins.block, ins.typ, ins.operands)
			m.instrs[m.instrs.len - 1].atomic_ord = ins.atomic_ord
			m.instrs[m.instrs.len - 1].inline = ins.inline
			m.instrs[m.instrs.len - 1].asm_id = ins.asm_id
		} else {
			vid := m.add_value(kind, vtyps[id - 1], vnames[id - 1], vindexes[id - 1])
			if int(vid) != id {
				return error('bitcode: value id drift at ${id}')
			}
		}
	}
	for fi in 0 .. nfunctions {
		for pid in fn_params[fi] {
			m.func_add_param(fi, ssa.ValueID(pid))
		}
		mut fblocks := []ssa.BlockID{cap: fn_blocks[fi].len}
		for bid in fn_blocks[fi] {
			fblocks << ssa.BlockID(bid)
		}
		m.funcs[fi].blocks = fblocks
		m.funcs[fi].is_c_extern = (fn_flags[fi] & 1) != 0
		m.funcs[fi].is_variadic = (fn_flags[fi] & 2) != 0
		m.funcs[fi].is_prototype = (fn_flags[fi] & 4) != 0
		m.funcs[fi].linkage = unsafe { ssa.Linkage(fn_link[fi]) }
		m.funcs[fi].call_conv = unsafe { ssa.CallConv(fn_conv[fi]) }
		m.funcs[fi].variadic_start = fn_varstart[fi]
	}
	return m
}

// rebuild_cache repopulates TypeStore intern keys in first-id-wins order so
// later get_* calls do not allocate duplicate types.
fn rebuild_cache(mut m ssa.Module) {
	for i, t in m.type_store.types {
		match t.kind {
			.int_t {
				key := if t.is_unsigned { 'u${t.width}' } else { 'i${t.width}' }
				if key !in m.type_store.cache {
					m.type_store.cache[key] = ssa.TypeID(i)
				}
			}
			.float_t {
				key := 'f${t.width}'
				if key !in m.type_store.cache {
					m.type_store.cache[key] = ssa.TypeID(i)
				}
			}
			.ptr_t {
				key := 'p${t.elem_type}'
				if key !in m.type_store.cache {
					m.type_store.cache[key] = ssa.TypeID(i)
				}
			}
			.array_t {
				key := 'a${t.elem_type}_${t.len}'
				if key !in m.type_store.cache {
					m.type_store.cache[key] = ssa.TypeID(i)
				}
			}
			.struct_t {
				if t.field_names.len == 0 {
					mut key := 'tuple'
					for f in t.fields {
						key += '_${f}'
					}
					if key !in m.type_store.cache {
						m.type_store.cache[key] = ssa.TypeID(i)
					}
				}
			}
			else {}
		}
	}
}
