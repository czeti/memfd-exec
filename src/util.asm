;------------------------------------------------------------------------------
; Thin wrapper for applying seals to a memfd file descriptor using fcntl(2).
;
; This function applies the write seal (F_SEAL_WRITE) to a file descriptor
; that supports sealing, such as one returned by memfd_create(2).  Sealing
; prevents further writes to the file, making it immutable.
;
; The syscall number SYS_fcntl and the constants F_ADD_SEALS and F_SEAL_WRITE
; are expected to be defined in the included "syscalls.inc".  Typical values
; on x86-64 Linux are:
;   - SYS_fcntl     : 72
;   - F_ADD_SEALS   : 1033
;   - F_SEAL_WRITE  : 0x0008
;
; The function makes no attempt to validate the file descriptor or the
; success of the operation; it simply invokes the syscall and returns the
; result to the caller.
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; Provides SYS_fcntl, F_ADD_SEALS, F_SEAL_WRITE

section .text

;------------------------------------------------------------------------------
; int seal_memfd(int fd);
;
; Applies the write seal to a memfd file descriptor using the fcntl(2)
; F_ADD_SEALS command.
;
; Parameters:
;   RDI : fd - file descriptor (should be a memfd that supports sealing)
;
; Returns:
;   On success, returns 0 in RAX.
;   On error, returns a negative error code (the negated errno value) in RAX.
;
; Registers modified:
;   RAX (syscall number and return value), RCX, R11 (syscall‑clobbered).
;   RSI and RDX are overwritten with the fcntl command and seal flag.
;   All other registers are preserved as per the calling convention.
;
; Side effects:
;   - The write seal is applied to the file descriptor, preventing any
;     subsequent write operations on it.
;   - The seal is permanent and cannot be removed (unless F_SEAL_SEAL is
;     also applied, which is not done here).
;
; Errors (typical):
;   - EBADF  (‑9)   : fd is not a valid open file descriptor.
;   - EINVAL (‑22)  : fd does not support sealing (e.g., not a memfd).
;   - EPERM  (‑1)   : The file descriptor already has the write seal applied,
;                     or sealing is not supported.
;
; Note: This function does NOT set the C library's errno; the raw syscall
; return value must be checked directly.
;------------------------------------------------------------------------------
global seal_memfd
seal_memfd:
    ; Set up the fcntl(2) arguments:
    ;   RDI already contains the file descriptor.
    ;   RSI = command (F_ADD_SEALS)
    ;   RDX = seal flags (F_SEAL_WRITE)
    mov rsi,    F_ADD_SEALS
    mov rdx,    F_SEAL_WRITE

    ; Invoke the fcntl syscall.
    mov eax,    SYS_fcntl
    syscall

    ; Return to caller (result is already in RAX).
    ret
