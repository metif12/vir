#ifndef VIR_H
#define VIR_H

/* vir C API — versioned separately from the .vir grammar. */
#define VIR_ABI_VERSION 1

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a parsed vir module. */
typedef void *VirModule;

/* Returns the C API ABI version (currently VIR_ABI_VERSION). */
int vir_abi_version(void);

/* Parses NUL-terminated .vir text into a module handle. Returns NULL on
 * failure; vir_last_error() then describes the problem. A non-NULL handle
 * must be released with vir_module_free(). */
VirModule vir_parse(const char *src);

/* Runs the default optimization pipeline on `m`. Returns 0 on success. */
int vir_optimize(VirModule m);

/* Verifies `m`. Returns 0 when the module is valid. */
int vir_verify(VirModule m);

/* Lowers `m` to an ELF64 relocatable object at `out_path` for `triple`.
 * Returns 0 on success. Only amd64 triples are supported in v1. */
int vir_compile(VirModule m, const char *triple, const char *out_path);

/* Returns a NUL-terminated description of the last error, or an empty
 * string if none. The pointer remains valid until the next libvir call;
 * copy it if you need to keep it. */
const char *vir_last_error(void);

/* Releases a module handle. Passing NULL is a no-op. */
void vir_module_free(VirModule m);

#ifdef __cplusplus
}
#endif

#endif /* VIR_H */
