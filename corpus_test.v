module main

import os
import vssa.optimize
import vssa.ssa

// test_vir_corpus_round_trips parses every testdata/*.vir file, checks the
// structured verifier is clean, and requires print(parse(print())) stability.
fn test_vir_corpus_round_trips() {
	dir := os.join_path(@VMODROOT, 'testdata')
	files := os.ls(dir)!
	assert files.len > 0, 'no corpus files in testdata/'
	for file in files {
		if !file.ends_with('.vir') {
			continue
		}
		path := os.join_path(dir, file)
		src := os.read_file(path)!
		mut m := ssa.module_from_text(src)!
		assert optimize.verify(m).len == 0, 'verify failed for ${file}'
		text := ssa.module_to_text(m)!
		mut m2 := ssa.module_from_text(text)!
		assert ssa.module_to_text(m2)! == text, 'round trip unstable for ${file}'
	}
}

// test_vir_corpus_optimizes requires the default pipeline to keep every
// corpus file verifiable with stable text.
fn test_vir_corpus_optimizes() {
	dir := os.join_path(@VMODROOT, 'testdata')
	files := os.ls(dir)!
	assert files.len > 0, 'no corpus files in testdata/'
	for file in files {
		if !file.ends_with('.vir') {
			continue
		}
		src := os.read_file(os.join_path(dir, file))!
		mut m := ssa.module_from_text(src)!
		optimize.optimize(mut m)
		assert optimize.verify(m).len == 0, 'verify failed after opt for ${file}'
		text := ssa.module_to_text(m)!
		mut m2 := ssa.module_from_text(text)!
		assert ssa.module_to_text(m2)! == text, 'opt round trip unstable for ${file}'
	}
}
