;------------------------------------------------------------------------------
; Minimal memfd creation and cleanup test program.
;
; This program tests the basic functionality of create_memfd by creating a
; memfd, then immediately closing it. It verifies that both operations succeed,
; and exits with status 0 on success or 1 on any error.
;
; Steps performed:
;   1. Call create_memfd with a name and flags = 0.
;   2. Check the return value; if negative, jump to error.
;   3. Close the obtained file descriptor using the close syscall.
;   4. Check the close result; if non‑zero, jump to error.
;   5. Exit with status 0.
;
; External function:
;   - create_memfd   : creates a memfd file descriptor
;
; System calls used directly:
;   - close          : close the memfd
;   - exit           : terminate process
;
; This serves as a simple smoke test for the memfd infrastructure.
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; Provides SYS_close, SYS_exit

extern create_memfd

section .data
    name db "test_memfd", 0          ; Name for the memfd (visible in /proc)

section .text
global _start

;------------------------------------------------------------------------------
; Entry point: _start
;------------------------------------------------------------------------------
_start:
    ; ------------------------------------------------------------------------
    ; Step 1: Create a memfd with no special flags.
    ; create_memfd(name, flags) where flags = 0 (no sealing allowed).
    ; ------------------------------------------------------------------------
    mov     rdi,    name               ; Pointer to the name string
    xor     esi,    esi                 ; flags = 0
    call    create_memfd

    ; ------------------------------------------------------------------------
    ; Step 2: Check the result of create_memfd.
    ; A negative return value indicates an error (e.g., ENOMEM, EMFILE).
    ; ------------------------------------------------------------------------
    test    eax, eax                    ; Set flags based on RAX
    js      .error                       ; Jump if sign bit set (negative)

    ; ------------------------------------------------------------------------
    ; Step 3: Close the file descriptor.
    ; close(fd); fd is in EAX (32‑bit, but safe as fds are small).
    ; ------------------------------------------------------------------------
    mov     edi,    eax                  ; fd to close (zero‑extended to 64‑bit)
    mov     eax,    SYS_close
    syscall

    ; ------------------------------------------------------------------------
    ; Step 4: Check the result of close.
    ; close returns 0 on success, -1 on error (with errno in negative? Actually
    ; raw syscall returns -errno on error, but here we test for non‑zero.
    ; The original code uses jnz, which will jump if eax is non‑zero.
    ; On success, eax = 0. On error, eax = -errno (negative), so jnz triggers.
    ; ------------------------------------------------------------------------
    test    eax,   eax                   ; Check if return value is zero
    jnz     .error                        ; Non‑zero indicates close failure

    ; ------------------------------------------------------------------------
    ; Step 5: Exit successfully with status 0.
    ; ------------------------------------------------------------------------
    xor     edi,    edi                   ; exit status 0
    mov     eax,    SYS_exit
    syscall

; ------------------------------------------------------------------------
; Error path: exit with status 1.
; ------------------------------------------------------------------------
.error:
    mov edi,    1                         ; exit status 1
    mov eax,    SYS_exit
    syscall
