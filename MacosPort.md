# macOS Port for harec

This document summarizes the changes made to port the [Hare](https://harelang.org) bootstrap compiler (`harec`) and its minimal test runtime (`rt/`) to macOS (Darwin), supporting Apple Silicon (`arm64`/`aarch64`) and Intel (`x86_64`) via QBE's `arm64_apple` and `amd64_apple` backends.

---

## 1. Background & Technical Challenges

Porting `harec` from ELF-based Unix platforms (Linux, FreeBSD, NetBSD, OpenBSD) to macOS required addressing several differences between ELF and Mach-O:

1. **Mach-O Section Syntax & Permissions**:
   - In ELF, functions and data are placed in individual sections like `.text.<name>` and `.data.<name>` with flags like `"ax"` or `"aw"` to enable `--gc-sections`.
   - In Mach-O, the `.section` directive requires both a segment and a section name (`segname, sectname`). Emitting `.section ".text.<name>", "ax"` creates a segment named `.text.<name>` that macOS does not mark executable, causing `EXC_BAD_ACCESS` / `SIGBUS` at runtime.
   - Mach-O accomplishes dead-code elimination via `-dead_strip` and `.subsections_via_symbols` without needing per-symbol section names.

2. **Array Symbols for Initialization and Finalization (`@init`, `@fini`, `@test`)**:
   - ELF targets use a linker script (`rt/hare.sc`) to collect `.data.hare_init_array`, etc., providing symbols like `__hare_init_array_start` and `__hare_init_array_end`.
   - Apple `ld` does not support GNU/LLVM linker scripts (`-T`). However, Apple `ld` natively generates section boundary symbols of the form `section$start$<segment>$<section>` and `section$end$<segment>$<section>`.

3. **System Calls & Entry Point**:
   - macOS does not support raw direct kernel syscalls (ABI is unstable and syscall numbers change across macOS versions). macOS binaries must link with `libSystem.dylib` (libc).
   - In hosted mode with libc, dyld enters `_main(int argc, char **argv, char **envp)` rather than a custom `_start`.
   - macOS lacks `pipe2(2)`, requiring emulation via `pipe(2)` and `fcntl(2)` (`FD_CLOEXEC`).

---

## 2. Summary of Changes

### A. Compiler Core & Code Emission

* **`include/qbe.h`**:
  - Introduced `enum target_format { FORMAT_ELF, FORMAT_MACHO };`.
  - Added `enum target_format format` to `struct qbe_program`.

* **`include/gen.h`**:
  - Added `enum target_format format` to `struct gen_context`.

* **`src/main.c`**:
  - Added support for target aliases `arm64`, `arm64_apple`, `aarch64_apple`, `aarch64-darwin`, `amd64`, `amd64_apple`, etc.
  - Added automatic detection of `FORMAT_MACHO` based on `DEFAULT_PLATFORM` (`darwin` or `macos`) and the target string.
  - Initialized `prog.format` and propagated format to code generation and emission.

* **`src/gen.c`**:
  - When targeting `FORMAT_MACHO`, `@init`, `@fini`, and `@test` tables are emitted into Mach-O sections:
    - `"__DATA"` `"__hare_init"`
    - `"__DATA"` `"__hare_fini"`
    - `"__DATA"` `"__hare_test"`
  - ELF behavior (`.data.hare_init_array`, etc.) remains untouched.

* **`src/emit.c`**:
  - Under `FORMAT_MACHO`:
    - `emit_func`: Omits `.section ".text.<name>" "ax"`, allowing QBE to emit `.text` (maps to `__TEXT,__text`).
    - `emit_data`: Omits per-symbol `.data.<name>` / `.bss.<name>`, allowing QBE to emit `.data` / `.bss` (`__DATA,__data` / `__DATA,__bss`).
    - Emits QBE native `thread data`, which QBE automatically maps to Mach-O thread-local variables (`__DATA,__thread_vars` and `__DATA,__thread_data`).

### B. Minimal Runtime (`rt/+darwin`)

* **`rt/+darwin/start.ha`**:
  - Implements hosted entry point `_main(c_argc: int, c_argv: *[*]*const u8, c_envp: *[*]nullable *const u8) void`.
  - Captures command-line arguments and environment pointers.
  - Calls `init()`, `.main()` (the compiled user program entry), `fini()`, and `exit(0)`.

* **`rt/+darwin/syscalls.ha`**:
  - Binds runtime routines to `libSystem.dylib` (`write`, `close`, `dup2`, `getpid`, `exit`, `fork`, `execve`, `wait4`, `kill`, `mmap`, `munmap`).
  - Implements `pipe2` using Darwin `pipe(2)` and `fcntl(2)` with `O_CLOEXEC`.
  - Implements Darwin process wait macros (`wifexited`, `wexitstatus`, `wtermsig`, `wifsignaled`).
  - Defines Darwin memory mapping and signal constants (`MAP_*`, `PROT_*`, `SIGABRT`, `SIGCHLD`).

* **`rt/+darwin/errno.ha`**:
  - Defines Darwin errno constants matching `<sys/errno.h>`.

* **`rt/+darwin/initfini.s`**:
  - Declares `.subsections_via_symbols` for dead-code stripping.
  - Aliases `___hare_init_array_start/end`, `___hare_fini_array_start/end`, and `___hare_test_array_start/end` to Apple `ld` section boundary symbols (`section$start$__DATA$"__hare_init"`, etc.).

* **`rt/+macos`**:
  - Symlink pointing to `rt/+darwin`.

### C. Build System

* **`configs/darwin.mk` & `configs/macos.mk`**:
  - Sets `PLATFORM = darwin`, `ARCH = aarch64`, `CC = cc`, `AS = as`, `LD = cc`, `QBE = qbe`.
  - Sets `HARECFLAGS = -N "" -m .main`.

* **`makefiles/darwin.mk` & `makefiles/macos.mk`**:
  - Configures `_rt_ha = rt/malloc+libc.ha`.
  - Configures `_rt_s = rt/+$(PLATFORM)/initfini.s`.
  - Sets `LDSCRIPT =` (no linker script required on Darwin).

* **`Makefile`**:
  - Added `-DDEFAULT_PLATFORM='"$(PLATFORM)"'`.
  - Sets `LDSCRIPT ?= -T rt/hare.sc` as fallback for ELF platforms.

* **`makefiles/tests.mk`**:
  - Replaced hardcoded `-T rt/hare.sc` with `$(LDSCRIPT)` across all test link rules.
  - Updated assembly rule for `$(HARECACHE)/rt.o` to pipe concatenated sources (`cat $(rt_s) | $(AS) $(ASFLAGS) -o $@ -`) to accommodate Apple's assembler not accepting multiple input files with `-o`.

---

## 3. Building and Verification

### Building on macOS

```sh
cp configs/darwin.mk config.mk
make
```

### Running the Test Suite

```sh
make check
```

**Results:**
```
39 tests:	39 passed	0 failed	in 20 seconds
```
All 39 test suites (`00-literals` through `38-if_let`) pass with 0 failures.

### Example Program

```hare
use rt;

fn puts(s: str) void = {
    rt::write(1, *(&s: **opaque), len(s));
    let nl = "\n";
    rt::write(1, *(&nl: **opaque), 1);
};

export fn main() void = {
    const greetings = [
        "Hello, world!",
        "¡Hola Mundo!",
        "Γειά σου Κόσμε!",
        "Привіт, світе!",
        "こんにちは世界！",
    ];
    for (let greeting .. greetings) {
        puts(greeting);
    };
};
```

Compiling and running:
```sh
# Set typedef path for rt module
export HARE_TD_rt=.cache/rt.td

# Compile Hare to QBE IL, then assemble and link
./.bin/harec -N "" -m .main -a arm64_apple -o greetings.ssa greetings.ha
qbe -t arm64_apple -o greetings.s greetings.ssa
cc -c -o greetings.o greetings.s
cc -o greetings greetings.o .cache/rt.o
./greetings
```

Output:
```
Hello, world!
¡Hola Mundo!
Γειά σου Κόσμε!
Привіт, світе!
こんにちは世界！
```

---

## 4. Comprehensive Porting Guide

This section explains the architecture of `harec` and details how to port it to a new operating system or object file format (such as macOS / Mach-O), including exactly which files need to be modified, created, and why.

### 4.1 Architecture Overview

`harec` is the bootstrap compiler for Hare written in C11. Its compilation pipeline operates as follows:
1. **Frontend**: Lexes and parses `.ha` source files into an AST (`src/parse.c`, `src/lex.c`).
2. **Type Checking & Semantic Analysis**: Resolves identifiers, typechecks expressions, and assigns types (`src/check.c`, `src/type_store.c`).
3. **QBE Intermediate Language Generation**: Lowers typed Hare declarations and expressions into QBE IL definitions (`src/gen.c`).
4. **QBE Code Emission**: Emits the in-memory QBE definitions into textual QBE Intermediate Language (`.ssa`) format (`src/emit.c`).
5. **Downstream Pipeline**:
   - `qbe` compiles the `.ssa` textual IL into assembly (`.s`).
   - The platform assembler (`as` / `clang -c`) compiles assembly into an object file (`.o`).
   - The platform linker (`ld` / `cc`) links the object files with the Hare runtime (`rt.o`) and standard libraries into an executable.

Because `harec` outputs QBE IL rather than machine code, porting `harec` involves:
1. Configuring target names, platform names, and build parameters.
2. Emitting QBE IL compatible with the platform's object file format (ELF vs Mach-O vs PE/COFF).
3. Implementing the minimal runtime (`rt/`) for process lifecycle, I/O, memory management, and array initialization.
4. Adapting the build and test system for platform-specific toolchains.

---

### 4.2 File-by-File Modification Details

Here is the complete breakdown of every file that must be modified or created.

#### 1. Compiler Header Files

* **`include/qbe.h`**:
  - **Purpose**: Defines QBE data structures representing programs, types, functions, and data blocks.
  - **Changes Required**:
    - Add an enum to distinguish the object file format:
      ```c
      enum target_format {
          FORMAT_ELF,
          FORMAT_MACHO,
      };
      ```
    - Add `enum target_format format;` to `struct qbe_program`.

* **`include/gen.h`**:
  - **Purpose**: Defines the code generation context `struct gen_context`.
  - **Changes Required**:
    - Add `enum target_format format;` to `struct gen_context` so code generation functions can query the target format.

---

#### 2. Compiler Source Files

* **`src/main.c`**:
  - **Purpose**: Entry point and CLI flag parsing for `harec`.
  - **Changes Required**:
    1. **Platform macro fallback**: Define `#ifndef DEFAULT_PLATFORM \n #define DEFAULT_PLATFORM "" \n #endif`.
    2. **Format selection**: Detect target format based on `DEFAULT_PLATFORM` (e.g. `darwin`, `macos`) and the `-a <arch>` target string (e.g. `apple`, `darwin`).
    3. **Architecture aliases**: Accept platform-specific architecture strings (e.g. `arm64`, `arm64_apple`, `aarch64_apple`, `aarch64-darwin`, `amd64_apple`) and map them to the canonical internal enum (`AARCH64`, `X86_64`).
    4. **Program initialization**: Initialize `struct qbe_program prog = { .format = format };`.

* **`src/gen.c`**:
  - **Purpose**: Translates AST declarations and expressions into QBE IL statements.
  - **Changes Required**:
    - Pass `ctx.format = out->format` when constructing `struct gen_context` in `gen()`.
    - Modify `@init`, `@fini`, and `@test` table emission in `gen_function_decl()`:
      - **ELF**: Emits section name `.data.hare_init_array`, `.data.hare_fini_array`, `.data.hare_test_array`.
      - **Mach-O**: Emits segment and section names `"__DATA"` `"__hare_init"`, `"__DATA"` `"__hare_fini"`, and `"__DATA"` `"__hare_test"`.

* **`src/emit.c`**:
  - **Purpose**: Serializes QBE IR into textual QBE assembly syntax.
  - **Changes Required**:
    - Update `emit_func()`:
      - **ELF**: Emits `section ".text.<func_name>" "ax"` to place each function in its own section for GNU ld `--gc-sections`.
      - **Mach-O**: Omit section directives entirely for functions (`function export $func(...)`). Mach-O relies on `.subsections_via_symbols` and `-dead_strip` instead of custom section names. Explicitly emitting non-`__TEXT` section names triggers fatal runtime memory permission errors (`SIGBUS`/`EXC_BAD_ACCESS`).
    - Update `emit_data()`:
      - **ELF**: Emits per-symbol `.data.<name>` or `.bss.<name>`.
      - **Mach-O**: Emits bare `data $name` (or `thread data $name` for thread-local variables), allowing QBE to place them in standard `__DATA` sections. If custom section/secflags are set (such as for `__DATA` `__hare_init`), emits `section "<seg>" "<sect>"`.
    - Thread-Local Storage (TLS):
      - Emits QBE's `thread data` keyword for `def->data.threadlocal` on Mach-O, letting QBE generate native Apple TLS structures (`__thread_vars` / `__thread_data`).

---

#### 3. Runtime Files (`rt/`)

The minimal runtime `rt/` provides low-level system services required by `harec` and test suites before the full Hare standard library is available.

* **`rt/+<platform>/start.ha`**:
  - **Purpose**: Defines the program entry point and bootstraps the runtime.
  - **Implementation**:
    - On hosted platforms (macOS / Darwin linking with `libSystem.dylib`), dyld jumps to `_main(int argc, char **argv, char **envp)`:
      ```hare
      @symbol("main") fn _main(c_argc: int, c_argv: *[*]*const u8, c_envp: *[*]nullable *const u8) void = {
          argc = c_argc;
          argv = c_argv;
          envp = c_envp;
          init();
          .main();
          fini();
          exit(0);
      };
      ```
    - Note the call to `.main()`: when compiling with `-m .main`, `harec` renames the user's `export fn main()` to `.main`, allowing `start.ha` to intercept execution at the C `_main`.

* **`rt/+<platform>/syscalls.ha`**:
  - **Purpose**: Implements required I/O, process, and memory management functions.
  - **Implementation**:
    - Direct syscalls (`@symbol("") fn ...`) are bound to C library symbols from `libSystem.dylib`:
      - I/O: `write`, `close`, `dup2`
      - Process: `fork`, `execve`, `wait4`, `getpid`, `kill`, `exit`
      - Memory: `mmap`, `munmap`
    - Emulate functions missing from macOS (e.g., `pipe2`):
      ```hare
      export fn pipe2(pipefd: *[2]int, flags: int) int = {
          let res = sys_pipe(pipefd);
          if (res != 0) return res;
          if (flags & O_CLOEXEC != 0) {
              sys_fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
              sys_fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
          };
          return 0;
      };
      ```
    - Define wait status decoders: `wifexited`, `wexitstatus`, `wtermsig`, `wifsignaled`.

* **`rt/+<platform>/errno.ha`**:
  - **Purpose**: Maps integer error numbers to OS error definitions matching `<sys/errno.h>`.

* **`rt/+<platform>/initfini.s`**:
  - **Purpose**: Exposes start and end boundary symbols for `@init`, `@fini`, and `@test` function pointer tables.
  - **Mach-O Implementation**:
    - Apple `ld` auto-generates section boundary symbols of the form `section$start$<SEGMENT>$<SECTION>`.
    - Darwin `as` assembly uses `.set` to alias Hare's expected symbols to the linker-provided boundary symbols:
      ```s
      .subsections_via_symbols

      .globl ___hare_init_array_start
      .globl ___hare_init_array_end
      .set ___hare_init_array_start, "section$start$__DATA$\"__hare_init\""
      .set ___hare_init_array_end,   "section$end$__DATA$\"__hare_init\""

      .globl ___hare_fini_array_start
      .globl ___hare_fini_array_end
      .set ___hare_fini_array_start, "section$start$__DATA$\"__hare_fini\""
      .set ___hare_fini_array_end,   "section$end$__DATA$\"__hare_fini\""

      .globl ___hare_test_array_start
      .globl ___hare_test_array_end
      .set ___hare_test_array_start, "section$start$__DATA$\"__hare_test\""
      .set ___hare_test_array_end,   "section$end$__DATA$\"__hare_test\""
      ```

* **`rt/+macos`**:
  - Symlink to `rt/+darwin` so builds using either `PLATFORM=darwin` or `PLATFORM=macos` locate the runtime directory.

* **Memory Allocator Selection**:
  - Set `_rt_ha = rt/malloc+libc.ha` in the platform makefile to use system `malloc`/`free` backed by `libSystem`.

---

#### 4. Build Configuration Files

* **`configs/<platform>.mk`** (`configs/darwin.mk`, `configs/macos.mk`):
  - Defines the toolchain and default flags:
    ```makefile
    PLATFORM = darwin
    ARCH = aarch64
    CC = cc
    AS = as
    LD = cc
    QBE = qbe
    AR = ar
    HARECFLAGS = -N "" -m .main
    ```

* **`makefiles/<platform>.mk`** (`makefiles/darwin.mk`, `makefiles/macos.mk`):
  - Configures runtime dependencies:
    ```makefile
    _rt_ha = rt/malloc+libc.ha
    _rt_s = rt/+$(PLATFORM)/initfini.s
    LDSCRIPT =
    ```

* **`Makefile`**:
  - Passes `-DDEFAULT_PLATFORM='"$(PLATFORM)"'` into `HAREC_CFLAGS`.
  - Sets `LDSCRIPT ?= -T rt/hare.sc` so that ELF platforms continue using the linker script while Darwin leaves `LDSCRIPT` empty.

* **`makefiles/tests.mk`**:
  - Replaces all hardcoded occurrences of `-T rt/hare.sc` with `$(LDSCRIPT)`.
  - Updates the `rt.o` compilation rule:
    ```makefile
    $(HARECACHE)/rt.o: $(rt_s)
    	@printf 'AS\t%s\t\n' '$@'
    	@cat $(rt_s) | $(AS) $(ASFLAGS) -o $@ -
    ```
    *(Apple `clang -c` / `as` does not allow specifying multiple input files with `-o`, so piping via `cat` makes it work across all platforms).*

---

### 4.3 Checklist for Porting to Another OS or Target

When porting `harec` to a future OS or architecture:

1. [ ] **Verify QBE Support**: Confirm `qbe` has a backend for the target architecture and operating system (e.g. `qbe -t ?`).
2. [ ] **Identify Object File Format**: Determine whether the target uses ELF, Mach-O, or PE/COFF. If new, add a variant in `include/qbe.h` (`enum target_format`).
3. [ ] **Check Section Directive Rules**: Check how the target's assembler and linker handle custom section names for code (`.text`) and data (`.data`).
4. [ ] **Implement Section Boundaries**: Check how the target linker collects `@init`, `@fini`, and `@test` table bounds (linker script vs compiler/linker symbols vs section markers).
5. [ ] **Entry Point Strategy**:
   - Freestanding: implements `_start` directly using raw syscalls.
   - Hosted: links with libc, intercepts `_main` via `-m .main`, and calls `init()`, `.main()`, `fini()`, and `exit()`.
6. [ ] **Implement Syscalls & Errno**: Provide `syscalls.ha` and `errno.ha` matching the target OS kernel or libc definitions.
7. [ ] **Create Configuration Files**: Add `configs/<platform>.mk` and `makefiles/<platform>.mk`.
8. [ ] **Run Test Suite**: Execute `make check` to validate all compiler features and runtime semantics.

---

### 4.4 Pitfalls & Troubleshooting

1. **Mach-O Segment Names and Permissions (`EXC_BAD_ACCESS` / `SIGBUS`)**:
   - In ELF, `.section ".text.foo","ax"` creates a section with allocatable and executable flags.
   - In Mach-O, the first parameter is the *segment* name. Creating a segment named `".text.foo"` results in an unmapped non-executable memory segment on Darwin. Leave section definitions out for standard functions so QBE emits them into `__TEXT,__text`.

2. **Quotes in Section Names with Apple ld**:
   - QBE preserves double quotes when emitting `section "__DATA" "__hare_init"`. Darwin's `as` produces an object file with literal quotes in the section name (`"__hare_init"`).
   - In `initfini.s`, you must escape the quotes: `"section$start$__DATA$\"__hare_init\""`.

3. **Multiple Files Passed to Apple `as`**:
   - Apple's `as` driver (clang) rejects `as -o out.o file1.s file2.s` with an error. Concatenating via `cat $(rt_s) | $(AS) $(ASFLAGS) -o $@ -` ensures single-stream input.

4. **Hosted Entry Points and Symbol Names**:
   - Darwin libc prefixes C symbols with an underscore `_` in assembly. When defining `@symbol("main")` in Hare, it compiles to `_main` in assembly, matching libc's expected entry point.


