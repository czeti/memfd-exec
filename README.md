# memfd-exec; Fileless ELF Loader for Linux x86-64

> Load and execute ELF binaries directly from memory using `memfd_create(2)` and `execveat(2)`, with no filesystem writes and optional immutability sealing. Implemented in hand-written NASM assembly with a Rust FFI integration layer.

[![Platform](https://img.shields.io/badge/platform-Linux%20x86--64-blue?style=flat-square)](https://kernel.org)
[![Language](https://img.shields.io/badge/language-NASM%20%7C%20Rust-orange?style=flat-square)](https://nasm.us)
[![License](https://img.shields.io/badge/license-MIT-red?style=flat-square)](#-legal-disclaimer)
[![Kernel](https://img.shields.io/badge/kernel-%3E%3D%203.17-green?style=flat-square)](https://man7.org/linux/man-pages/man2/memfd_create.2.html)
[![Contact](https://img.shields.io/badge/contact-Session-purple?style=flat-square)](#-contact--contributions)

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Architecture](#architecture)
  - [Assembly Modules](#assembly-modules)
  - [Rust Integration Layer](#rust-integration-layer)
- [ELF Validation](#elf-validation)
- [File Sealing](#file-sealing)
- [Project Structure](#project-structure)
- [Dependencies](#dependencies)
- [Building](#building)
  - [Build the Assembly Tests](#build-the-assembly-tests)
  - [Build the Rust Workspace](#build-the-rust-workspace)
  - [Run the Loader](#run-the-loader)
- [Make Targets](#make-targets)
- [Syscall Reference](#syscall-reference)
- [Error Handling](#error-handling)
- [Security Considerations](#security-considerations)
- [Testing](#testing)
- [Known Limitations](#known-limitations)

---

## Overview

**memfd-exec** is a low-level, fileless ELF execution engine for Linux x86-64. It accepts a raw ELF binary as an in-memory buffer, validates its structure, writes it into an anonymous kernel file descriptor (`memfd`), optionally seals the file against further modification, and then executes it via `execveat(2)`; all without touching the filesystem at any point.

The core loader is written entirely in x86-64 NASM assembly and exposes a C-compatible ABI, making it consumable from any language that supports foreign function interfaces. A Rust wrapper crate (`rust_src/`) demonstrates the integration pattern: it embeds a payload binary at compile time and invokes the loader through an `unsafe extern "C"` FFI boundary.

**Primary use cases:**

- Executing embedded payloads without creating temporary files on disk
- In-process execution of dynamically generated or fetched ELF images
- Research into Linux execution primitives and anonymous file descriptors
- Systems programming education covering assembly-level syscall usage

---

## How It Works

The execution pipeline follows five sequential stages:

```
In-memory ELF buffer
        │
        ▼
┌─────────────────────┐
│  1. ELF Validation  │  Check magic, class, endianness, type, machine,
│    (load_and_exec)  │  version, program headers, segment bounds,
└────────┬────────────┘  and entry point containment
         │
         ▼
┌─────────────────────┐
│  2. memfd Creation  │  memfd_create("memfd_payload", MFD_ALLOW_SEALING)
│    (create_memfd)   │  → anonymous file descriptor in kernel memory
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  3. ELF Write       │  write_all(fd, elf_buffer, size)
│     (write_all)     │  Retry loop handles partial writes
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  4. Sealing         │  fcntl(fd, F_ADD_SEALS, seal_flags)
│    (optional)       │  Makes the memfd immutable if seal_mask != 0
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  5. Execution       │  execveat(fd, "", argv, envp, AT_EMPTY_PATH)
│    (exec_memfd)     │  Replaces the current process with the payload
└─────────────────────┘
```

On success, `execveat` replaces the calling process entirely. The function never returns. On any failure, the memfd is closed, a negative errno value is returned, and the calling process continues normally.

---

## Architecture

### Assembly Modules

All core functionality resides in `src/`, written in NASM for the x86-64 System V ABI. Each module is a standalone translation unit assembled to a single `.o` object file.

---

#### `src/_start.asm`; `load_and_exec`

The top-level entry point and the only function a caller needs to invoke directly.

```c
int load_and_exec(
    const void   *elf_data,    // RDI: pointer to the ELF binary in memory
    size_t        size,        // RSI: total size of the binary in bytes
    char *const   argv[],      // RDX: null-terminated argument array
    char *const   envp[],      // RCX: null-terminated environment array, or NULL
    unsigned int  seal_flags   // R8:  bitmask of F_SEAL_* flags, or 0
);
```

Responsibilities:
- Validates the ELF header and all program headers
- Verifies that all `PT_LOAD` segments are within the provided buffer
- Confirms that `e_entry` falls within at least one loadable segment
- Orchestrates the call sequence: `create_memfd` → `write_all` → `fcntl` (if sealing) → `exec_memfd`
- Saves and restores all callee-saved registers (`RBP`, `RBX`, `R12`–`R15`)
- On any error path, closes the memfd before returning

---

#### `src/executor.asm`; `exec_memfd`

A thin wrapper around the `execveat(2)` system call using `AT_EMPTY_PATH`.

```c
int exec_memfd(
    int           fd,     // RDI: memfd file descriptor
    char *const   argv[], // RSI: argument array
    char *const   envp[]  // RDX: environment array
);
```

This function maps directly to:

```c
execveat(fd, "", argv, envp, AT_EMPTY_PATH);
```

The empty string pathname (`""`) is stored in `.rodata`. The `AT_EMPTY_PATH` flag instructs the kernel to treat `fd` as the executable directly, bypassing any path resolution.

---

#### `src/memfd.asm`; `create_memfd`

A minimal syscall wrapper for `memfd_create(2)`.

```c
int create_memfd(const char *name, unsigned int flags);
```

The caller passes `name` in `RDI` and `flags` in `RSI`. The function loads `SYS_memfd_create` (319) into `RAX` and executes `syscall`. The resulting file descriptor or negative errno is returned in `RAX`.

In `load_and_exec`, this is called with:
- `name` = `"memfd_payload"` (visible under `/proc/<pid>/fd/`)
- `flags` = `MFD_ALLOW_SEALING` (enables subsequent `F_ADD_SEALS` calls)

---

#### `src/writer.asm`; `write_all`

A POSIX-compliant retry loop around `write(2)`, handling partial writes correctly.

```c
ssize_t write_all(int fd, const void *buf, size_t count);
```

Returns `0` on complete success. On error, returns the negative errno value from the failing `write` syscall. If `write` returns `0` when `count > 0` (an anomalous kernel condition), the function synthesises and returns `-EIO` (`-5`).

The current buffer position and remaining byte count are tracked in `R8` and `R10` respectively across iterations.

---

#### `src/util.asm`; `seal_memfd`

A focused wrapper for applying `F_SEAL_WRITE` to a memfd via `fcntl(2)`.

```c
int seal_memfd(int fd);
```

Invokes `fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE)`. Once applied, the write seal is permanent: no further write operations can be performed on the file descriptor.

> **Note:** `load_and_exec` performs sealing inline via a direct syscall rather than calling `seal_memfd`, so that the caller-supplied `seal_flags` bitmask (which may include flags beyond `F_SEAL_WRITE`) is passed through unchanged.

---

### Rust Integration Layer

Located in `rust_src/`, this is a Cargo workspace that demonstrates calling `load_and_exec` from Rust.

#### `rust_src/src/main.rs`

- Embeds the payload binary at compile time using `include_bytes!("../../payload/implant.bin")`
- Constructs a null-terminated `argv` array via `make_argv(&["implant"])`
- Declares the extern function with a diverging (`!`) return type
- Calls `load_and_exec` through an `unsafe` block

#### `rust_src/build.rs`

The build script automates the assembly → static library → Rust link pipeline:

1. Locates the `ar` archiver (requires `binutils`)
2. For each object file in `../build/`, wraps it in a `lib<name>.a` static archive placed in Cargo's `OUT_DIR`
3. Emits `cargo:rustc-link-lib=static=<name>` directives for each archive
4. Emits `cargo:rustc-link-arg=-no-pie` to disable PIE, which is incompatible with the absolute relocations in the assembly objects

---

## ELF Validation

`load_and_exec` performs the following structural checks before creating a memfd. Any failure returns `-EINVAL` immediately.

| Check | Field | Expected Value |
|---|---|---|
| Minimum size |; | ≥ 64 bytes |
| Magic number | `e_ident[0..4]` | `\x7fELF` |
| ELF class | `e_ident[EI_CLASS]` | `ELFCLASS64` (2) |
| Data encoding | `e_ident[EI_DATA]` | `ELFDATA2LSB` (1) |
| Object type | `e_type` | `ET_EXEC` (2) or `ET_DYN` (3) |
| Machine | `e_machine` | `EM_X86_64` (62) |
| Version | `e_version` | `EV_CURRENT` (1) |
| Program header offset | `e_phoff` | ≥ 64 bytes |
| Program header count | `e_phnum` | > 0 |
| Program header entry size | `e_phentsize` | = 56 bytes |
| Program header table bounds | `e_phoff + e_phnum * 56` | ≤ `size` |

For each `PT_LOAD` segment in the program header table, the following are also verified:

- `p_offset + p_filesz` ≤ `size` (segment is within the provided buffer)
- `p_memsz` ≥ `p_filesz` (memory size is at least as large as file size)

Finally, the entry point (`e_entry`) must fall within the virtual address range (`p_vaddr` to `p_vaddr + p_memsz`) of at least one `PT_LOAD` segment. If no such segment is found, `-EINVAL` is returned.

---

## File Sealing

The `seal_flags` parameter of `load_and_exec` accepts any combination of `F_SEAL_*` bitmask values. When `seal_flags` is non-zero, the function calls:

```c
fcntl(fd, F_ADD_SEALS, seal_flags);
```

before executing the payload. Commonly used seal flags:

| Flag | Value | Effect |
|---|---|---|
| `F_SEAL_WRITE` | `0x0008` | Prevents any further `write(2)` calls on the fd |
| `F_SEAL_SHRINK` | `0x0002` | Prevents file size from being decreased |
| `F_SEAL_GROW` | `0x0004` | Prevents file size from being increased |
| `F_SEAL_SEAL` | `0x0001` | Prevents any further seals from being added |

Sealing is only possible because the memfd is created with `MFD_ALLOW_SEALING`. A memfd created without this flag will cause `fcntl(F_ADD_SEALS, ...)` to return `-EPERM`.

Pass `0` as `seal_flags` to skip sealing entirely.

---

## Project Structure

```
.
├── include/
│   └── syscalls.inc          # Syscall numbers and flag constants (NASM)
├── src/
│   ├── _start.asm            # load_and_exec; main entry point
│   ├── executor.asm          # exec_memfd; execveat(2) wrapper
│   ├── memfd.asm             # create_memfd; memfd_create(2) wrapper
│   ├── writer.asm            # write_all; retry-loop write(2) wrapper
│   └── util.asm              # seal_memfd; fcntl(2) sealing wrapper
├── tests/
│   ├── test_executor.asm     # Tests for exec_memfd
│   ├── test_load_and_exec.asm# End-to-end integration tests
│   ├── test_memfd.asm        # Tests for create_memfd
│   ├── test_sealing.asm      # Tests for seal_memfd
│   └── test_writer.asm       # Tests for write_all
├── payload/
│   └── exit42.asm            # Minimal ELF payload: exits with code 42
├── rust_src/
│   ├── src/
│   │   └── main.rs           # Rust FFI entry point
│   └── build.rs              # Cargo build script (ASM → static libs)
├── build/                    # Assembled object files (generated)
└── Makefile                  # Unified build system
```

---

## Dependencies

### Required

| Tool | Purpose | Install |
|---|---|---|
| `nasm` | Assembles `.asm` sources to ELF64 object files | `apt install nasm` |
| `ld` (GNU binutils) | Links object files into executables | `apt install binutils` |
| `ar` (GNU binutils) | Packages objects into static archives for Rust | `apt install binutils` |
| Rust + Cargo | Builds the Rust integration layer | [rustup.rs](https://rustup.rs) |

### Runtime

| Requirement | Details |
|---|---|
| Linux kernel ≥ 3.17 | `memfd_create(2)` was introduced in kernel 3.17 |
| Linux kernel ≥ 3.19 | `execveat(2)` was introduced in kernel 3.19 |
| x86-64 architecture | All assembly is architecture-specific |
| `F_ADD_SEALS` support | Available from kernel 3.17 with `memfd_create` |

---

## Building

### Build the Assembly Tests

Assemble all source and test modules, build the `exit42` payload, and link all test binaries:

```bash
make
```

This produces:
- `build/*.o`; assembled object files
- `payload/implant.bin`; the `exit42` test payload ELF
- `build/test_memfd`, `build/test_writer`, `build/test_executor`, `build/test_sealing`, `build/test_load_and_exec`; linked test executables

### Build the Rust Workspace

The Rust build depends on the assembled object files. The `build` Makefile target handles both:

```bash
make build         # debug build
make release       # optimised release build
```

Cargo will automatically invoke `build.rs`, which packages the object files from `build/` into static libraries and links them.

> **Important:** Run `make` (or `make asm`) before `cargo build` if building Rust manually, to ensure the object files exist in `build/` before the build script runs.

### Run the Loader

```bash
make run
```

This builds the payload, assembles all objects, builds the Rust binary in debug mode, and executes it. The embedded `implant.bin` payload will be loaded in-memory and executed, replacing the current process. For the default `exit42` payload, the process will exit with code 42.

---

## Make Targets

| Target | Description |
|---|---|
| `all` | Build ASM test binaries (default) |
| `asm` | Build ASM objects and payload only |
| `build` | Build Rust workspace in debug mode |
| `release` | Build Rust workspace in release mode |
| `test` | Run Rust unit and integration tests |
| `check` | Fast Rust compilation check (no codegen) |
| `fmt` | Format Rust source with `rustfmt` |
| `lint` | Run `clippy` with `-D warnings` |
| `doc` | Generate and open Rust documentation |
| `run` | Build and run the Rust loader binary |
| `clean` | Remove all build artefacts (ASM + Rust) |
| `help` | Print all available targets |

Pass extra arguments to the Rust binary with `ARGS`:

```bash
make run ARGS="--some-flag"
```

---

## Syscall Reference

All syscall numbers and constants are defined in `include/syscalls.inc`.

| Symbol | Value | Syscall / Constant |
|---|---|---|
| `SYS_write` | 1 | `write(2)` |
| `SYS_close` | 3 | `close(2)` |
| `SYS_lseek` | 8 | `lseek(2)` |
| `SYS_fcntl` | 72 | `fcntl(2)` |
| `SYS_exit` | 60 | `exit(2)` |
| `SYS_memfd_create` | 319 | `memfd_create(2)` |
| `SYS_execveat` | 322 | `execveat(2)` |
| `MFD_ALLOW_SEALING` | `0x0002` | memfd creation flag |
| `F_ADD_SEALS` | `1033` | fcntl command |
| `F_SEAL_WRITE` | `0x0008` | Write seal flag |
| `AT_EMPTY_PATH` | `0x1000` | execveat flag |
| `EINVAL` | `22` | Invalid argument errno |

---

## Error Handling

All functions follow the Linux syscall convention: a non-negative value indicates success; a negative value is the negated `errno`.

| Returned Value | Meaning |
|---|---|
| `0` | Success (for `write_all`, `seal_memfd`) |
| `≥ 0` | File descriptor (for `create_memfd`) |
| `-EINVAL` (`-22`) | ELF validation failure, or bad sealing argument |
| `-ENOMEM` (`-12`) | Kernel memory exhaustion |
| `-EMFILE` (`-24`) | Per-process file descriptor limit reached |
| `-EIO` (`-5`) | `write(2)` returned 0 when bytes remained |
| `-EBADF` (`-9`) | Invalid file descriptor passed to fcntl or write |
| `-EPERM` (`-1`) | Sealing not permitted (missing `MFD_ALLOW_SEALING`) |

`load_and_exec` propagates errors from `create_memfd`, `write_all`, and `fcntl` without modification. On all error paths, any open memfd is explicitly closed before returning.

---

## Security Considerations

- **No filesystem writes.** The ELF image exists only in an anonymous kernel buffer, not on any mounted filesystem. It will not appear in directory listings.
- **Input validation.** `load_and_exec` validates every structural field relevant to safe memory access before writing to a memfd or executing. Malformed or truncated ELF images are rejected with `-EINVAL`.
- **File sealing.** When `F_SEAL_WRITE` is applied before execution, the memory region backing the memfd becomes immutable. The kernel will reject any attempt to modify the file after this point, even from within the loader process.
- **No PIE.** The assembly objects use absolute relocations and must be linked without Position Independent Executable support (`-no-pie`). This is enforced via `build.rs`. Deployers should be aware of the security implications of non-PIE executables in environments where ASLR is a required mitigation.
- **File descriptor visibility.** The memfd is named `"memfd_payload"` and will appear under `/proc/<pid>/fd/` for the duration of its lifetime. If anonymity is required, pass an empty string as the name to `create_memfd`.

---

## Testing

The `tests/` directory contains standalone assembly test programs, each linked against the relevant source objects and exercising a specific module:

| Test Binary | Module Under Test | What It Tests |
|---|---|---|
| `build/test_memfd` | `create_memfd` | memfd creation, return value validation |
| `build/test_writer` | `write_all` | Full writes, partial write retry, error propagation |
| `build/test_executor` | `exec_memfd` | execveat invocation with the `exit42` payload |
| `build/test_sealing` | `seal_memfd` | `F_SEAL_WRITE` application, post-seal write rejection |
| `build/test_load_and_exec` | `load_and_exec` | End-to-end: ELF validation, write, seal, exec |

Run all tests after building:

```bash
./build/test_memfd
./build/test_writer
./build/test_executor
./build/test_sealing
./build/test_load_and_exec
```

For the Rust test suite:

```bash
make test
```

The `exit42` payload (`payload/exit42.asm`) is a minimal self-contained ELF that calls `SYS_exit` with code 42. It is embedded into the executor tests to provide a known, deterministic execution target.

---

## Known Limitations

- **x86-64 Linux only.** The syscall numbers, register conventions, and ELF structure assumptions are all specific to Linux on x86-64. No portability layer exists.
- **`execveat` requires kernel ≥ 3.19.** Systems running older kernels will receive `-ENOSYS` from `exec_memfd`.
- **`exec_memfd` does not return on error.** The current implementation has no `ret` instruction after the `syscall`. If `execveat` fails, execution falls through to the next function in the text section. In the context of `load_and_exec` this is benign because the caller checks the return value and handles the error; but `exec_memfd` must not be called directly in any context where a failed exec needs to be handled gracefully.
- **No dynamic linker support for staged loading.** The loader writes the raw ELF to a memfd and relies on the kernel's `execveat` to handle dynamic linking. There is no manual segment mapping, relocation processing, or interpreter invocation within the loader itself.
- **Single payload per process.** Because `execveat` replaces the calling process entirely, the loader can only be invoked once per process lifetime on the happy path.

---

## License

MIT
---

## Contact & Contributions

For suggestions and reports.

**Contact via [Session](https://getsession.org)**

Session is an end-to-end encrypted, decentralised messenger requiring no phone number, email address, or other identifying information to use. I appreciate it as an appropriate medium for discussions.

> 📎 **Session ID**: *(05113397ab0111e2ec2615d8a0d71499d8eaa5b5a92ebf5e2f2d79cbd858c73830)*
