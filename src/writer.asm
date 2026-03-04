;------------------------------------------------------------------------------
; Safe, retry‑loop wrapper for the write system call (x86‑64 Linux).
;
; This function repeatedly invokes the write syscall until all requested bytes
; have been written or an error occurs. It correctly handles partial writes
; (e.g., when writing to pipes, sockets, or interrupted syscalls).
;
; The implementation assumes the standard x86‑64 syscall calling convention:
;   - RDI : file descriptor
;   - RSI : pointer to the data buffer
;   - RDX : number of bytes to write
;
; The syscall number SYS_write is expected to be defined in "syscalls.inc"
; (typically 1 for x86‑64).
;
; No validation of arguments is performed; the caller must ensure the buffer
; is valid and the file descriptor is open for writing.
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; Provides SYS_write constant

section .text

;------------------------------------------------------------------------------
; ssize_t write_all(int fd, const void *buf, size_t count);
;
; Writes exactly 'count' bytes from 'buf' to the file descriptor 'fd'.
; If a write system call writes fewer bytes than requested, the function
; retries with the remaining data. This loop continues until all bytes are
; written or a hard error occurs.
;
; Parameters (incoming registers, as per syscall convention):
;   RDI : fd         - file descriptor (must be valid and writable)
;   RSI : buf        - pointer to the source buffer (must be readable)
;   RDX : count      - number of bytes to write (may be zero)
;
; Returns:
;   On success: 0 (RAX = 0). All requested bytes have been written.
;   On error:   A negative error code (the negated errno value from the
;               underlying write syscall) is returned. The exact number of
;               bytes written before the error is indeterminate.
;
; Special error case:
;   If a write syscall returns 0 (which should not happen when 'count' > 0),
;   the function returns -5 (‑EIO) to signal an unexpected zero‑length write.
;
; Registers modified:
;   RAX (syscall result and return value)
;   RCX, R11 (clobbered by the syscall instruction)
;   R8, R10 (used as local copies of buffer pointer and remaining count)
;   RSI, RDX may be overwritten during syscall setup (but their original
;   values are no longer needed after the call).
;
; All other registers are preserved as per the calling convention.
;
; Side effects:
;   - Data from the buffer is written to the file descriptor.
;   - The file descriptor's file offset (if any) is advanced by the total
;     number of bytes written.
;
; Errors (typical):
;   - EBADF  (‑9)   : fd is not a valid file descriptor or not open for writing.
;   - EFAULT (‑14)  : buf points outside accessible address space.
;   - EINTR  (‑4)   : The write was interrupted by a signal before any data
;                     was written. (This function will retry automatically.)
;   - EIO    (‑5)   : Low‑level I/O error (or our synthetic error for zero write).
;   - ENOSPC (‑28)  : No space left on device.
;   - EPIPE  (‑32)  : Broken pipe (e.g., writing to a pipe with no reader);
;                     may also generate a SIGPIPE signal.
;
; Note: This function does NOT set the C library's errno; the raw syscall
; return value must be checked directly.
;------------------------------------------------------------------------------
global write_all
write_all:
    ; Preserve the original buffer pointer and count in non‑volatile
    ; registers for the retry loop.  (The first instruction is a no‑op
    ; and may be a placeholder; it is retained to match the original code.)
    mov rdi,    rdi          ; No effect; kept for compatibility
    mov r8,     rsi          ; r8 = original buffer pointer (current position)
    mov r10,    rdx          ; r10 = remaining bytes to write

.loop:
    test r10,   r10          ; Check if all bytes have been written
    jz .done                  ; If zero remaining, we are done (success)

    ; Prepare and execute the write system call.
    ; Arguments: RDI = fd (unchanged), RSI = current buffer position,
    ;            RDX = remaining count, RAX = syscall number.
    mov rdi,    rdi          ; Keep fd (no change, redundant but harmless)
    mov rsi,    r8            ; Current position in buffer
    mov rdx,    r10           ; Number of bytes still to write
    mov eax,    SYS_write     ; Syscall number for write
    syscall

    ; Check the result of the write syscall.
    cmp rax,    0             ; Compare return value with 0
    jl .error                  ; If negative, an error occurred

    ; If the syscall returned exactly 0, it is considered an error.
    ; According to POSIX, write(2) returns 0 only when 'count' is 0,
    ; which should never happen here because r10 > 0.  Hence, a zero
    ; return indicates an unexpected kernel behaviour (e.g., for certain
    ; special file types) and is treated as an I/O error.
    je .error_zero

    ; Partial write: update remaining count and buffer pointer.
    sub r10,    rax           ; Subtract the number of bytes just written
    add r8,     rax           ; Advance the buffer pointer
    jmp .loop                  ; Retry with the updated state

.error:
    ; Return the negative error code already in RAX from the syscall.
    ret

.error_zero:
    ; Special case: write returned 0.  Synthesize -EIO (input/output error)
    ; to indicate an unexpected zero‑length write.
    mov rax,     -5                ; -5 corresponds to -EIO on Linux
    ret

.done:
    ; Success; all bytes written.
    xor eax,     eax               ; Return 0
    ret
