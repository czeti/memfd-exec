;------------------------------------------------------------------------------
; Execute a program from a file descriptor using execveat(2) with AT_EMPTY_PATH.
;
; This function invokes the execveat system call with the AT_EMPTY_PATH flag,
; allowing execution of a file descriptor (e.g., a memfd) as an executable.
; It is designed for use with file descriptors that already contain an
; executable image, such as those created by memfd_create(2) and populated
; with code.
;
; The syscall number SYS_execveat and the flag AT_EMPTY_PATH are expected
; to be defined in the included "syscalls.inc".  Typical values on x86-64
; Linux are:
;   - SYS_execveat   : 322
;   - AT_EMPTY_PATH  : 0x1000
;
; WARNING: This function does not contain a 'ret' instruction after the
;          syscall.  If execveat succeeds, it does not return.  If it fails,
;          control will fall through to whatever code follows this function,
;          leading to undefined behaviour.  In a properly designed program,
;          the failure case should be handled or the function should return
;          the error code.  This implementation leaves that responsibility
;          to the caller or assumes that execveat will always succeed.
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; Provides SYS_execveat, AT_EMPTY_PATH

section .rodata
    empty_path db 0                  ; Null‑terminated empty string for pathname

section .text

;------------------------------------------------------------------------------
; int exec_memfd(int fd, char *const argv[], char *const envp[]);
;
; Executes the program contained in the file descriptor 'fd' using the
; execveat(2) system call with the AT_EMPTY_PATH flag.  This is analogous
; to calling execve(2) on a file descriptor that represents an executable.
;
; Parameters (incoming registers, as per syscall convention):
;   RDI : fd   - file descriptor referencing the executable (must be opened
;                for reading and have been populated with an ELF image)
;   RSI : argv - pointer to a null‑terminated array of argument strings
;                (may be NULL or point to an array containing at least one
;                entry, typically the program name)
;   RDX : envp - pointer to a null‑terminated array of environment strings
;                (may be NULL, which inherits the current environment)
;
; Returns:
;   On success, execveat does not return - the calling process is replaced.
;   On error, the syscall returns -1 and the function returns the negated
;   error code in RAX.  However, due to the missing 'ret' instruction,
;   the actual behaviour on error is undefined (see WARNING above).
;
; Registers modified:
;   RAX (syscall number and return value), RCX, R11 (syscall‑clobbered).
;   RSI, RDX, R10, R8 are overwritten with syscall arguments.
;   All other registers are preserved as per the calling convention,
;   but note that on successful exec, all process state is replaced.
;
; Side effects:
;   - If successful, the current process image is completely replaced by
;     the program loaded from the file descriptor.
;   - No files opened with the close‑on‑exec flag (FD_CLOEXEC) are closed,
;     except those marked for closure by the kernel.
;   - The file descriptor itself remains open across exec unless the
;     FD_CLOEXEC flag was set when it was created.
;
; Errors (typical, if execveat fails):
;   - EACCES (‑13) : The file is not a regular file, or execute permission
;                    is denied.
;   - ENOENT (‑2)  : The file descriptor does not refer to a valid executable.
;   - ENOMEM (‑12) : Insufficient kernel memory.
;   - EINVAL (‑22) : The file descriptor does not support AT_EMPTY_PATH,
;                    or the executable image is corrupted.
;   - ENOSYS (‑38) : The kernel does not support execveat (unlikely on modern
;                    Linux).
;
; Important notes:
;   - The AT_EMPTY_PATH flag tells the kernel to ignore the pathname
;     (pointed to by empty_path) and use the file descriptor 'fd' directly.
;   - The empty_path string is a single null byte, placed in the .rodata
;     section for read‑only access.
;   - This function is typically used with memfd file descriptors that have
;     been sealed (e.g., with F_SEAL_WRITE) to ensure immutability.
;
; Pitfall:
;   The absence of a 'ret' instruction after the syscall means that if
;   execveat fails (returning -1), execution will continue into whatever
;   code happens to be placed next in the text section.  This is almost
;   certainly not intended and can lead to crashes or security issues.
;   Production code should either handle the error (e.g., by returning
;   the error code) or ensure that execveat never fails.
;------------------------------------------------------------------------------
global exec_memfd
exec_memfd:
    ; Save the third argument (envp) into r10, as required by the syscall
    ; calling convention (rdx is used for argv, r10 for envp).
    mov r10,    rdx          ; r10 = envp

    ; Set up argv for the syscall (already in rdx, but preserved by the move)
    mov rdx,    rsi          ; rdx = argv (second argument)

    ; Set the AT_EMPTY_PATH flag.
    mov r8,     AT_EMPTY_PATH

    ; Use the empty string as the pathname (ignored due to AT_EMPTY_PATH).
    mov rsi,    empty_path

    ; Invoke execveat.
    mov eax,    SYS_execveat
    syscall

    ; If execveat succeeds, execution does not continue.
    ; If it fails, control falls through to the next instruction
    ; (which is whatever follows this function in memory).
    ; No 'ret' instruction is present - this is a deliberate
    ; choice in the original code, but it is a significant pitfall.
