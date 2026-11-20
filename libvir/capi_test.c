/* Pure-C end-to-end check of the libvir API: parse -> optimize -> verify
 * -> compile an ELF object, using only vir.h and C standard library calls.
 * Run against the built libvir shared library with a C compiler. */

#include "vir.h"

#include <stdio.h>

static const char *kAddSrc =
    "vir 1\n"
    "target os - arch - ptr 8 endian little\n"
    "type %t0 = void\n"
    "type %t1 = i32\n"
    "const %v1 %t1 \"1\"\n"
    "func 0 \"main\" -> %t1 linkage external callconv c_decl params (%v2 \"x\" : %t1)\n"
    "@b0 \"entry\" :\n"
    "  %v3 = add %t1, %v2, %v1\n"
    "  %v4 = ret %t1, %v3\n"
    "detached\n";

static int fail(const char *what) {
    fprintf(stderr, "capi_test: %s failed: %s\n", what, vir_last_error());
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: capi_test <out.o>\n");
        return 2;
    }
    if (vir_abi_version() != VIR_ABI_VERSION) {
        return fail("abi_version");
    }

    VirModule m = vir_parse(kAddSrc);
    if (m == NULL) {
        return fail("parse");
    }
    int rc = 0;
    if (vir_optimize(m) != 0) {
        rc = fail("optimize");
    } else if (vir_verify(m) != 0) {
        rc = fail("verify");
    } else if (vir_compile(m, "amd64-linux-gnu", argv[1]) != 0) {
        rc = fail("compile");
    }
    vir_module_free(m);
    if (rc != 0) {
        return rc;
    }

    FILE *f = fopen(argv[1], "rb");
    if (f == NULL) {
        fprintf(stderr, "capi_test: cannot open output object\n");
        return 1;
    }
    unsigned char magic[4];
    size_t n = fread(magic, 1, sizeof(magic), f);
    fclose(f);
    if (n != sizeof(magic) || magic[0] != 0x7f || magic[1] != 'E' ||
        magic[2] != 'L' || magic[3] != 'F') {
        fprintf(stderr, "capi_test: output is not an ELF object\n");
        return 1;
    }

    printf("capi_test: ok (abi=%d, elf=%02x%02x%02x%02x)\n", VIR_ABI_VERSION,
           magic[0], magic[1], magic[2], magic[3]);
    return 0;
}
