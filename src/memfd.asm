;------------------------------------------------------------------------------
; Thin wrapper for the memfd_create system call (x86-64 Linux).
;
; This function invokes the memfd_create syscall without modifying any
; argument registers. It relies on the caller to have set up the syscall
; arguments according to the standard Linux x86-64 syscall convention.
;
; The syscall number SYS_memfd_create is expected to be defined in the
; included "syscalls.inc" file (typically 319 for x86-64).
;
; Note: This is a minimal, low-level interface. No validation, error
; handling, or C library errno setting is performed. The caller is
; responsible for interpreting the return value and handling failures.
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; Provides SYS_memfd_create constant

section .text

;------------------------------------------------------------------------------
; int create_memfd(void);
;
; Invokes the memfd_create system call.
;
; The caller MUST have placed the following arguments in the designated
; registers before calling this function:
;   - RDI : name (pointer to a null-terminated string, may be NULL)
;   - RSI : flags (unsigned int, bitmask of MFD_* constants)
;
; Returns:
;   On success, a non‑negative file descriptor is returned in RAX.
;   On error, a negative error code (the negated errno value) is returned in RAX.
;
; Registers modified:
;   RAX (syscall number and return value), RCX (syscall‑clobbered), R11 (flags).
;   All other registers are preserved as per the calling convention.
;
; Side effects:
;   - A new anonymous file descriptor is created in the calling process.
;   - The file descriptor will be closed on exec if the MFD_CLOEXEC flag is set.
;
; Errors (typical):
;   - EINVAL : flags include unknown bits.
;   - EFAULT : name pointer is invalid.
;   - ENOMEM : insufficient kernel memory.
;   - EMFILE : per‑process limit on file descriptors reached.
;   - ENFILE : system‑wide limit on file descriptors reached.
;
; Note: This function does NOT set the C library's errno; the raw syscall
; return value must be checked directly.
;------------------------------------------------------------------------------
global create_memfd
create_memfd:
    mov eax,    SYS_memfd_create      ; Load the syscall number for memfd_create
    syscall                         ; Invoke the kernel
    ret                             ; Return to caller (result already in RAX)
