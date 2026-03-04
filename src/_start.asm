;------------------------------------------------------------------------------
; ELF in‑memory loader using memfd_create and execveat.
;
; This function validates that a given buffer contains a valid, executable
; ELF file for the current architecture (x86‑64), copies it into an anonymous
; file descriptor created with memfd_create, optionally applies file seals,
; and then executes it using exec_memfd (which wraps execveat with AT_EMPTY_PATH).
;
; It is designed for scenarios where an ELF binary must be loaded directly
; from memory and executed without touching the filesystem, such as in
; self‑contained applications or secure code injection.
;
; The function performs extensive validation of the ELF header and program
; headers to ensure the binary is well‑formed and that all segments lie
; within the provided buffer. It also verifies that the entry point falls
; within a loadable segment.
;
; External dependencies:
;   - create_memfd   : creates a new memfd file descriptor
;   - write_all      : writes the entire buffer to the memfd
;   - exec_memfd     : executes the program from the memfd using execveat
;
; Syscalls used directly:
;   - fcntl (F_ADD_SEALS) : optional sealing of the memfd
;   - close               : closes the memfd on error
;
; Constants (provided by "syscalls.inc"):
;   SYS_fcntl, F_ADD_SEALS, SYS_close, MFD_ALLOW_SEALING, etc.
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; System call numbers and flags

extern create_memfd                    ; int create_memfd(const char *name, unsigned int flags)
extern write_all                        ; ssize_t write_all(int fd, const void *buf, size_t count)
extern exec_memfd                        ; int exec_memfd(int fd, char *const argv[], char *const envp[])

section .data
    default_name db "memfd_payload", 0   ; Default name for the memfd (visible in /proc/pid/fd)

section .text

;------------------------------------------------------------------------------
; int load_and_exec(const void *elf_data, size_t size, char *const argv[],
;                   char *const envp[], unsigned int seal_flags);
;
; Loads an ELF binary from memory and executes it using a memfd.
;
; Parameters (incoming registers, System V AMD64 ABI):
;   RDI : elf_data - pointer to the ELF binary in memory (must remain valid
;                    until the function returns, i.e., until after exec)
;   RSI : size     - total size of the ELF binary in bytes
;   RDX : argv     - pointer to a null‑terminated array of argument strings
;                    (passed directly to exec_memfd)
;   RCX : envp     - pointer to a null‑terminated array of environment strings
;                    (passed directly to exec_memfd)
;   R8  : seal_flags - bitmask of seal flags to apply (e.g., F_SEAL_WRITE);
;                      if zero, no sealing is performed.
;
; Returns:
;   On success, the function does not return; the process is replaced.
;   On error, a negative error code is returned (e.g., -EINVAL, -ENOMEM).
;
; Registers preserved:
;   The function saves and restores all callee‑saved registers (RBP, RBX, R12‑R15)
;   as required by the ABI. All others may be clobbered.
;
; Side effects:
;   - Creates a memfd file descriptor.
;   - Writes the entire ELF image into that memfd.
;   - Optionally applies seals via fcntl(F_ADD_SEALS).
;   - Executes the program from the memfd, replacing the current process.
;   - If an error occurs before exec, the memfd is closed and the function returns.
;
; Error conditions (returned as negative errno values):
;   - EINVAL : ELF header validation failed (wrong magic, class, data, type,
;              machine, version, or program header format); or the entry point
;              does not fall inside any loadable segment; or the binary exceeds
;              the provided buffer; or the size is too small (less than 64 bytes).
;   - Any error from create_memfd (e.g., ENOMEM, EMFILE) is passed through.
;   - Any error from write_all (e.g., EIO, ENOSPC) is passed through.
;   - Any error from fcntl sealing (e.g., EINVAL, EPERM) is passed through.
;
; Assumptions and constraints:
;   - The ELF binary must be a valid 64‑bit (ELFCLASS64) executable (ET_EXEC or ET_DYN)
;     for x86‑64 (EM_X86_64), with ELFDATA2LSB data encoding.
;   - The program header table must be present, with entries of size 56 bytes
;     (the standard size for 64‑bit ELF).
;   - At least one loadable segment (p_type == PT_LOAD) must exist, and the
;     entry point must lie within the virtual address range of one such segment.
;   - All loadable segments must be entirely contained within the provided buffer
;     (i.e., file offset + file size ≤ total buffer size).
;   - The entry point must be within the first loadable segment that contains it,
;     but the code does not enforce that the file offset of that segment is zero;
;     this is typical for ET_DYN (PIE) where the entry point is an offset from base.
;
; Performance considerations:
;   - The entire ELF binary is copied into the memfd via write_all, which uses
;     efficient retry loops. For large binaries, this involves a full memory‑to‑kernel
;     copy, which may be acceptable for typical payloads.
;   - Validation loops over all program headers (O(n) where n ≤ 65535), but this
;     is negligible for normal ELF files.
;
; Security notes:
;   - The function performs rigorous checks on the ELF structure to prevent
;     loading malformed or malicious binaries that could cause out‑of‑bounds reads.
;   - After optional sealing, the memfd becomes immutable (if F_SEAL_WRITE is applied),
;     preventing further modifications.
;   - The memfd is created with MFD_ALLOW_SEALING to enable subsequent sealing.
;   - If sealing is requested, the function calls fcntl directly (not a wrapper)
;     with the provided seal flags.
;   - On any error path, the memfd is closed to avoid leaking file descriptors.
;------------------------------------------------------------------------------
global load_and_exec
load_and_exec:
    ; Preserve callee‑saved registers (ABI requirement).
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Initialize memfd fd to -1 (invalid) so that error paths can close it safely.
    mov rbp,    -1

    ; Save arguments in callee‑saved registers for later use.
    mov r12,     rdi          ; r12 = elf_data
    mov r13,     rsi          ; r13 = size
    mov r14,     rdx          ; r14 = argv
    mov r15,     rcx          ; r15 = envp
    mov rbx,     r8           ; rbx = seal_flags

    ; Basic size check: an ELF header is at least 64 bytes.
    cmp r13,     64
    jb  .invalid               ; If size < 64, cannot be a valid ELF file

    ; Verify ELF magic number: 0x7F 'E' 'L' 'F'.
    mov rdi,             r12
    cmp dword [rdi],     0x464c457f   ; Little‑endian: 0x7F followed by 'E','L','F'
    jne .invalid

    ; Check ELF class: must be 64‑bit (ELFCLASS64 = 2).
    cmp byte [rdi+4],    2
    jne .invalid

    ; Check data encoding: must be little‑endian (ELFDATA2LSB = 1).
    cmp byte [rdi+5],    1
    jne .invalid

    ; Check ELF type: must be executable (ET_EXEC = 2) or shared object (ET_DYN = 3).
    movzx eax,   word [r12+16]      ; e_type
    cmp eax,     2
    je .type_ok
    cmp eax,     3
    jne .invalid
.type_ok:

    ; Check machine type: must be x86‑64 (EM_X86_64 = 62).
    movzx eax,   word [r12+18]      ; e_machine
    cmp eax,     62
    jne .invalid

    ; Check ELF version: must be 1 (EV_CURRENT).
    mov eax,     dword [r12+20]       ; e_version
    cmp eax,     1
    jne .invalid

    ; Check program header offset (e_phoff); must be at least 64 bytes
    ; (i.e., program headers cannot overlap the ELF header).
    mov rax,     qword [r12+32]       ; e_phoff
    cmp rax,     64
    jb  .invalid

    ; Number of program header entries (e_phnum). Must be non‑zero.
    movzx rcx,   word [r12+56]      ; e_phnum
    test rcx,    rcx
    jz  .invalid

    ; Size of each program header entry (e_phentsize). Must be 56 bytes
    ; (the standard size for 64‑bit ELF). This ensures we can safely index.
    movzx rdx,   word [r12+54]      ; e_phentsize
    cmp rdx,     56
    jne .invalid

    ; Check that the entire program header table fits inside the buffer.
    ; total_phdr_size = e_phnum * e_phentsize
    ; end_of_phdr_table = e_phoff + total_phdr_size
    push rax                       ; Save e_phoff on stack (will be used later)
    imul rcx,    rdx                  ; rcx = total size of program header table
    add rax,     rcx                   ; rax = end offset of program header table
    cmp rax,     r13                   ; Must be ≤ total buffer size
    ja  .invalid_pop               ; If beyond buffer, invalid

    ; Now we know the program header table is fully contained in the buffer.

    movzx r8,    word [r12+56]        ; r8 = e_phnum (number of program headers); reload
    pop r9                         ; r9 = e_phoff (popped from stack)

    ; Prepare for loop over program headers:
    ; rcx = e_phnum (loop counter)
    ; rsi = offset of current program header (starting at e_phoff)
    ; r10 = counter for loadable segments that contain the entry point
    ; r11 = e_entry (entry point address)
    mov rcx,     r8
    mov rsi,     r9
    xor r10,     r10
    mov r11,     qword [r12+24]        ; e_entry

.ph_loop:
    test rcx,    rcx                   ; If no more headers, exit loop
    jz   .ph_done

    ; Calculate pointer to current program header: elf_data + offset
    lea rdi,     [r12 + rsi]            ; rdi points to current program header entry

    ; Check program header type (p_type). We are interested in PT_LOAD (1).
    mov eax,     dword [rdi]
    cmp eax,     1
    jne .ph_next                     ; Skip non‑loadable segments

    ; For a loadable segment, verify that the segment's file data lies within the buffer.
    ; p_offset (file offset of segment) + p_filesz (size in file) must be ≤ total size.
    mov rax,     qword [rdi+8]           ; p_offset
    mov rdx,     qword [rdi+32]          ; p_filesz
    add rax,     rdx                      ; end offset of segment in file
    cmp rax,     r13                      ; Compare with buffer size
    ja  .invalid                       ; If segment extends beyond buffer, invalid

    ; Ensure p_filesz ≤ p_memsz? Not strictly required for validation, but we check
    ; that p_filesz is not greater than p_memsz? Actually original code checks
    ; p_filesz (at rdi+32) against p_memsz (at rdi+40). Let's follow original:
    ;   mov rax, qword [rdi+40]       ; p_memsz
    ;   cmp rax, rdx                  ; p_memsz compared to p_filesz? Wait original:
    ;   mov rax, qword [rdi+40]       ; p_memsz
    ;   cmp rax, rdx                   ; Actually original: cmp rax, rdx (rdx = p_filesz)
    ;   jb  .invalid                   ; if p_memsz < p_filesz, invalid.
    ; Yes, they check that p_memsz is at least p_filesz.
    ; Also they compare e_entry against segment's vaddr range.
    mov rax,     qword [rdi+40]          ; p_memsz
    cmp rax,     rdx                      ; p_memsz must be ≥ p_filesz
    jb  .invalid

    ; Check if the entry point falls within this segment's virtual address range.
    ; p_vaddr (rdi+16) to p_vaddr + p_memsz (but note: entry point is a virtual address,
    ; not a file offset). We compare e_entry with p_vaddr and p_vaddr + p_memsz.
    mov rax,     qword [rdi+16]          ; p_vaddr
    cmp r11,     rax                      ; if e_entry < p_vaddr, not in this segment
    jb  .ph_next
    add rax,     qword [rdi+40]          ; rax = p_vaddr + p_memsz
    cmp r11,     rax                      ; if e_entry ≥ p_vaddr + p_memsz, not in this segment
    jae .ph_next

    ; Entry point lies inside this loadable segment; increment the counter.
    inc r10

.ph_next:
    add rsi,     56                       ; Move to next program header entry
    dec rcx
    jmp .ph_loop

.ph_done:
    ; After processing all program headers, ensure at least one loadable segment
    ; contained the entry point.
    test r10,    r10
    jz  .invalid

    ; All ELF validation passed. Now create a memfd with sealing allowed.
    mov rdi,     default_name            ; Name for the memfd (visible in /proc)
    mov esi,     MFD_ALLOW_SEALING       ; Allow subsequent sealing
    call create_memfd
    test eax,    eax                     ; Check for error (negative return)
    js  .error_no_close               ; If error, jump to cleanup (no fd to close)
    mov ebp,     eax                       ; Save memfd fd in ebp (callee‑saved, 32‑bit safe)

    ; Write the entire ELF image into the memfd.
    mov rdi,     rbp                       ; fd
    mov rsi,     r12                       ; buffer (elf_data)
    mov rdx,     r13                       ; size
    call write_all
    test eax,    eax                       ; write_all returns 0 on success, negative on error
    jnz .error                           ; If error, close fd and return

    ; If seal_flags is non‑zero, apply the requested seals using fcntl.
    test rbx,    rbx
    jz   .exec                           ; Skip sealing if no flags

    ; Direct fcntl syscall: fd in rdi, F_ADD_SEALS in rsi, seal_flags in rdx.
    mov rdi,     rbp
    mov esi,     F_ADD_SEALS
    mov edx,     ebx                          ; seal_flags (e.g., F_SEAL_WRITE)
    mov eax,     SYS_fcntl
    syscall
    test eax,    eax                          ; fcntl returns 0 on success, -1 on error
    jnz .error                              ; If sealing fails, close fd and return

.exec:
    ; Execute the program from the memfd.
    ; exec_memfd takes fd (rdi), argv (rsi), envp (rdx); our args already in r14, r15.
    mov rdi,     rbp
    mov rsi,     r14
    mov rdx,     r15
    call exec_memfd

    ; If exec_memfd returns, it failed. Fall through to error handling.

.error:
    ; Save the error code (rax) before closing the fd.
    push rax
    ; Close the memfd.
    mov rdi,     rbp
    mov eax,     SYS_close
    syscall
    pop rax
    jmp .error_no_close

.invalid_pop:
    pop rax                                 ; Discard saved e_phoff from stack
.invalid:
    mov rax,     -EINVAL                         ; Return -EINVAL

.error_no_close:
    ; Restore callee‑saved registers and return.
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
