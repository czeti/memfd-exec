;------------------------------------------------------------------------------
; Test program for memfd sealing functionality.
;
; This program demonstrates and verifies that applying the write seal
; (F_SEAL_WRITE) to a memfd prevents further write operations.
;
; Steps performed:
;   1. Create a memfd with sealing allowed (MFD_ALLOW_SEALING).
;   2. Write an initial string to the memfd.
;   3. Apply the write seal using seal_memfd (which wraps fcntl(F_ADD_SEALS)).
;   4. Attempt to write a single byte to the sealed memfd.
;   5. Verify that the write fails (returns -1 / negative error).
;   6. Close the memfd and exit with status 0 on success, 1 on any failure.
;
; External functions:
;   - create_memfd   : creates a memfd file descriptor
;   - write_all      : writes all bytes to the memfd
;   - seal_memfd     : applies F_SEAL_WRITE to the memfd
;
; System calls used directly:
;   - write          : attempt to write after sealing (expect failure)
;   - close          : close the memfd
;   - exit           : terminate process
;
; Expected behaviour:
;   - The initial write must succeed.
;   - Sealing must succeed.
;   - The subsequent write must fail (return negative).
;   - If any step fails, the program exits with status 1.
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; Provides SYS_write, SYS_close, SYS_exit, MFD_ALLOW_SEALING

extern create_memfd
extern write_all
extern seal_memfd

section .data
    name db         "seal_test", 0          ; Name for the memfd (visible in /proc)
    data db         "initial data", 0        ; Initial data to write (null‑terminated string)
    data_len equ     $ - data            ; Length of initial data (excluding null)
    dummy db        "x", 0                  ; Single byte used for the write attempt after sealing

section .text
global _start

;------------------------------------------------------------------------------
; Entry point: _start
;------------------------------------------------------------------------------
_start:
    ; ------------------------------------------------------------------------
    ; Step 1: Create a memfd with sealing allowed.
    ; ------------------------------------------------------------------------
    mov rdi,     name                    ; Pointer to name string
    mov esi,     MFD_ALLOW_SEALING        ; Flags: allow future sealing operations
    call create_memfd
    test eax,    eax                     ; Check for error (negative return)
    js  .error                         ; Jump if sign set (negative)

    ; Save the file descriptor in a callee‑saved register (r12).
    mov r12,     rax                       ; r12 = memfd fd

    ; ------------------------------------------------------------------------
    ; Step 2: Write the initial data to the memfd.
    ; ------------------------------------------------------------------------
    mov rdi,     r12                       ; fd
    lea rsi,     [data]                     ; Buffer with initial data
    mov rdx,     data_len                   ; Number of bytes to write
    call write_all
    test eax,    eax                       ; write_all returns 0 on success
    jnz .error                           ; Non‑zero indicates failure

    ; ------------------------------------------------------------------------
    ; Step 3: Apply the write seal to the memfd.
    ; seal_memfd(fd) applies F_SEAL_WRITE (and only that seal, as implemented).
    ; ------------------------------------------------------------------------
    mov rdi,     r12                       ; fd
    call seal_memfd
    test eax,    eax                       ; seal_memfd returns 0 on success
    jnz .error                           ; Non‑zero indicates failure (e.g., fd not a memfd)

    ; ------------------------------------------------------------------------
    ; Step 4: Attempt to write after sealing.
    ; This write should fail with -EBADF, -EINVAL, or -EPERM (typically -9, -22, or -1).
    ; We only check that the return value is negative (sign flag set).
    ; ------------------------------------------------------------------------
    mov rdi,     r12                       ; fd (now sealed)
    lea rsi,     [dummy]                    ; Single byte buffer
    mov rdx,     1                          ; One byte
    mov eax,     SYS_write
    syscall
    test eax,    eax                       ; Check if result is non‑negative
    jns .error                           ; If >=0 (including 0), it unexpectedly succeeded

    ; ------------------------------------------------------------------------
    ; Step 5: Clean up and exit successfully.
    ; ------------------------------------------------------------------------
    mov rdi,    r12                       ; fd to close
    mov eax,    SYS_close
    syscall

    ; Exit with status 0.
    xor edi,     edi                        ; Exit status 0
    mov eax,     SYS_exit
    syscall

; ------------------------------------------------------------------------
; Error path: exit with status 1.
; ------------------------------------------------------------------------
.error:
    mov edi,     1                          ; Exit status 1
    mov eax,     SYS_exit
    syscall
