/* CornSyrup C ABI — pkb/particles <-> CFX bundle converter, and the CFX language as data.
 *
 * The library is cornsyrup.dll on Windows, libcornsyrup.so on Linux and libcornsyrup.dylib on
 * macOS, with the same functions on each: `cargo xtask capi` assembles it in dist/capi with this
 * header, the syntax tree's JSON Schema (cfx-ast.schema.json), the cfxlib it reads and the CMake
 * files that set it up, each platform's build in lib/<os>-<arch>/ (dist/capi/README.md). On
 * Windows link the import library cornsyrup.lib; on Linux and macOS link the library itself
 * (cc host.c -L<its folder> -lcornsyrup), and give the host an rpath to the folder it ships in: the
 * host records the name inside the file, its soname libcornsyrup.so or its install name
 * @rpath/libcornsyrup.dylib. A host that loads it at run time loads it by that file name. Keep the
 * cfxlib folder beside the library. The static library cargo also builds is cornsyrup_capi.
 * On WebAssembly (WASI preview 1, lib/wasi-wasm32/) it is the static library libcornsyrup.a, which
 * a host built with wasi-sdk links in, and the module cornsyrup.wasm, which a WASI runtime loads;
 * both have the standard library compiled in, so no cfxlib goes with them, and a panic traps rather
 * than returning CS_INTERNAL.
 * All strings are NUL-terminated UTF-8; the _w functions take their paths as UTF-16 instead.
 * Every function may be called from any thread; each thread has its own last error. A CsSession
 * is the exception: it is used on the thread that made it.
 *
 * Every conversion returns a CsStatus: CS_OK, or the kind of failure. After any call,
 * cornsyrup_last_error gives the calling thread's reason for a failure, cornsyrup_last_diagnostics
 * the warnings of a conversion that succeeded, and cornsyrup_last_report both as JSON, each placed.
 * The library prints nothing.
 *
 * A conversion is configured by the CsOptions it is passed and by nothing else: the library reads
 * no environment variable.
 *
 * Files or memory: each conversion takes paths, or has a _mem form on memory — a .pkb as bytes, a
 * bundle as a CsBundle, and what the library hands back in a CsBuffer. What the library hands out,
 * the host frees with the function named for it; on a failure every out-parameter is NULL or
 * zeroed, so there is nothing to free.
 *
 * The CFX language as data, as JSON:
 *   cornsyrup_parse      bundle -> syntax tree: every file as its author wrote it
 *   cornsyrup_print      syntax tree -> bundle of CFX text
 *   cornsyrup_build_ast  syntax tree -> .pkb; a failure is placed at the tree's node
 *   cornsyrup_resolve    bundle -> resolved effect: its objects, and its programs with every name
 *                        resolved and every value typed, for a host that runs or converts effects
 *   cornsyrup_engine_api the engine functions a program can call, with their signatures
 *
 * This header is written by hand; capi/tests/header.rs holds it to the Rust definitions.
 */
#ifndef CORNSYRUP_H
#define CORNSYRUP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What a call returns. */
typedef enum CsStatus {
    CS_OK = 0,
    /* A null pointer, a path that is not UTF-8, an option this library does not know. */
    CS_INVALID_ARGUMENT = 1,
    /* A file or folder could not be read or written. */
    CS_IO = 2,
    /* Not a .pkb/.particles this library reads, or a bundle (or a tree) that does not parse or build. */
    CS_BAD_INPUT = 3,
    /* Well-formed input this library cannot convert (e.g. more registers than bytecode addresses). */
    CS_UNSUPPORTED = 4,
    /* A bug in the library, such as a panic caught at the boundary (on WebAssembly a panic traps). */
    CS_INTERNAL = 5
} CsStatus;

/* A UTF-16 code unit, which the _w functions take their paths in: wchar_t on Windows, where that is
 * what a path is, and 16 bits elsewhere, where wchar_t is wider. */
#ifdef _WIN32
typedef wchar_t CsChar16;
#else
typedef uint16_t CsChar16;
#endif

/* CsOptions.flags: decompile without putting library calls back into the code. The bundle still
 * builds; it is less readable, and much faster to write. */
#define CS_NO_RECONSTRUCT 0x1u

/* CsOptions.flags: cornsyrup_parse also puts the library modules the bundle imports in the tree,
 * each marked "library": true. */
#define CS_AST_LIBRARY 0x2u

/* Called as each program of a decompile finishes: how many are done, how many there are, and
 * CsOptions.user. It must return (no longjmp). */
typedef void (*CsProgress)(uint32_t done, uint32_t total, void *user);

/* A session: the library, and what is built from it, kept between conversions. Opaque. */
typedef struct CsSession CsSession;

/* How to convert. Zeroed with size set, it is the defaults:  CsOptions o = { sizeof o };
 * A NULL options pointer means the same. */
typedef struct CsOptions {
    /* sizeof(CsOptions), so a later version can add fields at the end: a library reads an older
     * header's smaller struct, and takes the fields it lacks as zero. */
    size_t size;
    /* CS_NO_RECONSTRUCT, CS_AST_LIBRARY, or 0. An unknown bit is CS_INVALID_ARGUMENT. */
    uint32_t flags;
    /* A CFX library directory (a cfxlib), UTF-8, searched before the installation's (the cfxlib
     * beside this library, then the one beside the host's executable; on WebAssembly, the standard
     * library compiled into this one), or NULL. */
    const char *library;
    /* Decompile progress, or NULL. A build reports none. */
    CsProgress progress;
    /* Passed to progress as it is. */
    void *user;
    /* A session made on this thread by cornsyrup_session_new to convert in, or NULL for a new one
     * for the call. Not with library: a session has its own. */
    CsSession *session;
} CsOptions;

/* Bytes the library allocated: a .pkb, or UTF-8 text (JSON). data[len] is a NUL that len does not
 * count, so text is also a C string. Free with cornsyrup_buffer_free, which zeroes it; change
 * neither field before then. A zeroed CsBuffer frees as nothing. */
typedef struct CsBuffer {
    uint8_t *data;
    size_t len;
} CsBuffer;

/* A bundle in memory: its files by relative name, with / between the parts ("code.cfx",
 * "lib/helpers.cfx", "meshes/owl.pkmm"), as bytes. Opaque. */
typedef struct CsBundle CsBundle;

/* The version, NUL-terminated: the one every CornSyrup program of this release reports. Static
 * storage; do not free. */
const char *cornsyrup_version(void);

/* ---- Conversions on files ---------------------------------------------------------------------- */

/* .pkb/.particles (input) -> .cfxb bundle directory (outdir), with the default options. */
CsStatus cornsyrup_decompile(const char *input, const char *outdir);

/* .pkb/.particles (input) -> .cfxb bundle directory (outdir), as options says (NULL: defaults). */
CsStatus cornsyrup_decompile_with(const char *input, const char *outdir, const CsOptions *options);

/* .cfxb bundle directory (indir) -> .pkb/.particles (output), with the default options. */
CsStatus cornsyrup_build(const char *indir, const char *output);

/* .cfxb bundle directory (indir) -> .pkb/.particles (output), as options says (NULL: defaults). */
CsStatus cornsyrup_build_with(const char *indir, const char *output, const CsOptions *options);

/* Diagnostic: decompile+reassemble input into output (engine-faithful). Stores the number of
 * blobs reassembled in *blobs unless blobs is NULL. */
CsStatus cornsyrup_reassemble(const char *input, const char *output, size_t *blobs);

/* The same conversions with NUL-terminated UTF-16 paths, on every platform. On Windows they reach
 * every path Windows allows, UTF-8 or not; elsewhere a path is turned into UTF-8, and one with a
 * lone surrogate is CS_INVALID_ARGUMENT. CsOptions.library stays UTF-8. */
CsStatus cornsyrup_decompile_w(const CsChar16 *input, const CsChar16 *outdir, const CsOptions *options);
CsStatus cornsyrup_build_w(const CsChar16 *indir, const CsChar16 *output, const CsOptions *options);
CsStatus cornsyrup_reassemble_w(const CsChar16 *input, const CsChar16 *output, size_t *blobs);

/* ---- Buffers and bundles ----------------------------------------------------------------------- */

/* Free a buffer a call filled, and zero it. NULL, or a zeroed buffer, frees nothing. */
void cornsyrup_buffer_free(CsBuffer *buf);

/* A new, empty bundle. Never NULL. Free with cornsyrup_bundle_free. */
CsBundle *cornsyrup_bundle_new(void);

/* Free a bundle. NULL does nothing. */
void cornsyrup_bundle_free(CsBundle *bundle);

/* Add or replace the file name with a copy of the len bytes at data (NULL with len 0: empty). A
 * name that is empty, absolute, has a \ or a . or .. part is CS_INVALID_ARGUMENT. */
CsStatus cornsyrup_bundle_set(CsBundle *bundle, const char *name, const void *data, size_t len);

/* Remove the file name. A name the bundle does not have is not an error. */
CsStatus cornsyrup_bundle_remove(CsBundle *bundle, const char *name);

/* How many files the bundle has; 0 for NULL. */
size_t cornsyrup_bundle_count(const CsBundle *bundle);

/* The name of the i-th file, in name order; NULL past the end. Valid until the bundle changes or is
 * freed. */
const char *cornsyrup_bundle_name(const CsBundle *bundle, size_t i);

/* The bytes of the file name, borrowed: *data and *len are valid until the bundle changes or is
 * freed. A name the bundle does not have is CS_INVALID_ARGUMENT. */
CsStatus cornsyrup_bundle_get(const CsBundle *bundle, const char *name, const uint8_t **data, size_t *len);

/* A bundle directory, read into a new bundle in *out: every .cfx file under it (the bundle files and
 * its own modules) and every .pkmm. */
CsStatus cornsyrup_bundle_read_dir(const char *dir, CsBundle **out);

/* Every file of the bundle, written into the directory dir, making the folders a name needs. A
 * functions.cfx already in dir is kept, as a decompile keeps it, and a diagnostic says so. */
CsStatus cornsyrup_bundle_write_dir(const CsBundle *bundle, const char *dir);

/* The same with the directory as NUL-terminated UTF-16. */
CsStatus cornsyrup_bundle_read_dir_w(const CsChar16 *dir, CsBundle **out);
CsStatus cornsyrup_bundle_write_dir_w(const CsBundle *bundle, const CsChar16 *dir);

/* ---- Conversions on memory --------------------------------------------------------------------- */

/* The len bytes of a .pkb/.particles at pkb -> a new bundle in *out, as options says. */
CsStatus cornsyrup_decompile_mem(const void *pkb, size_t len, const CsOptions *options, CsBundle **out);

/* A bundle -> the bytes of its .pkb/.particles in *pkb. Its imports read the bundle's own .cfx
 * files first, then the library; a Mesh sampler's .pkmm is checked when the bundle holds it. */
CsStatus cornsyrup_build_mem(const CsBundle *bundle, const CsOptions *options, CsBuffer *pkb);

/* Does the bundle build? CS_OK with the build's warnings, or the build's failure; nothing is written. */
CsStatus cornsyrup_check_mem(const CsBundle *bundle, const CsOptions *options);

/* cornsyrup_reassemble on memory: the len bytes at pkb reassembled into *out, and the number of
 * blobs in *blobs unless blobs is NULL. */
CsStatus cornsyrup_reassemble_mem(const void *pkb, size_t len, CsBuffer *out, size_t *blobs);

/* ---- Sessions ------------------------------------------------------------------------------------ */

/* A session for options' library (NULL: the installation's) in *out: the library, the standard
 * library and the reconstruction database, loaded once and used by every call given it in
 * CsOptions.session, on this thread. options->session must be NULL. */
CsStatus cornsyrup_session_new(const CsOptions *options, CsSession **out);

/* Free a session, on the thread that made it (on another, it is left, and cornsyrup_last_error says
 * so). NULL does nothing. */
void cornsyrup_session_free(CsSession *session);

/* ---- The CFX language as data ----------------------------------------------------------------- */

/* The version of the syntax tree this library reads and writes: a tree's "version". */
uint32_t cornsyrup_ast_version(void);

/* The syntax tree's JSON Schema, NUL-terminated (also include/cfx-ast.schema.json). Static storage;
 * do not free. */
const char *cornsyrup_ast_schema(void);

/* The syntax tree of a bundle, as JSON, in *ast: every .cfx file as its author wrote it — names
 * unresolved, templates and functions as declared, literals as written, each node with the byte
 * range of its file it was read from and the comments around it. With CS_AST_LIBRARY, the library
 * modules the bundle imports too. */
CsStatus cornsyrup_parse(const CsBundle *bundle, const CsOptions *options, CsBuffer *ast);

/* The len bytes of a syntax tree's JSON at ast, printed as CFX text into a new bundle in *out: every
 * file but the library's, in the decompiler's canonical form. JSON that is not a tree of this
 * version — an unknown kind or field — is CS_BAD_INPUT, placed at its node. */
CsStatus cornsyrup_print(const char *ast, size_t len, const CsOptions *options, CsBundle **out);

/* The len bytes of a syntax tree's JSON at ast, built into the bytes of its .pkb in *pkb: printed,
 * and the text built. A failure or a warning is placed at the tree's node it is in (the "node" of
 * cornsyrup_last_report, a JSON Pointer); a library module the tree changes is not built, and a
 * warning says so. */
CsStatus cornsyrup_build_ast(const char *ast, size_t len, const CsOptions *options, CsBuffer *pkb);

/* The resolved effect of a bundle, as JSON, in *effect: its objects, each with its schema class
 * and typed fields, and each layer's programs with templates merged, functions inlined, every name
 * resolved and every value typed, as tables of nodes. It is read, not built: to change an effect,
 * change its syntax tree. */
CsStatus cornsyrup_resolve(const CsBundle *bundle, const CsOptions *options, CsBuffer *effect);

/* The engine's functions, as JSON, in *table: every function a program can call, with each
 * overload's argument and result types. */
CsStatus cornsyrup_engine_api(CsBuffer *table);

/* ---- What the last call had to say ----------------------------------------------------------- */

/* The calling thread's last failure, copied into buf (len bytes) NUL-terminated; returns its length
 * in bytes without the NUL, 0 when the last call succeeded. A message that does not fit is cut at a
 * character boundary, and the return value is >= len: call again with a buffer of return + 1
 * bytes. A NULL buf (or len 0) only measures. */
size_t cornsyrup_last_error(char *buf, size_t len);

/* The warnings and notes of the calling thread's last conversion, one per line
 * ("file:line:col: warning: message"), copied as cornsyrup_last_error copies. 0 when there were
 * none or the call failed. */
size_t cornsyrup_last_diagnostics(char *buf, size_t len);

/* The calling thread's last call as JSON, in *report:
 *   {"status": "bad_input", "error": {"message", "text", "file", "line", "col", "byte", "node"},
 *    "diagnostics": [{"severity", "message", "file", "line", "col", "byte", "node"}]}
 * each place field there when it is known; "error" is null after a call that succeeded, and "node"
 * is the JSON Pointer of the syntax-tree node a failure or warning is in, when the call was given a
 * tree. This call does not change what it reports. */
CsStatus cornsyrup_last_report(CsBuffer *report);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CORNSYRUP_H */
