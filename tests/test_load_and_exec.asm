;------------------------------------------------------------------------------
; Test harness for the ELF in‑memory loader (load_and_exec).
;
; This program exercises the load_and_exec function with various ELF binaries:
;   - A null buffer / zero length (should return -EINVAL)
;   - A buffer too small to be an ELF header (should return -EINVAL)
;   - A buffer with correct ELF magic but wrong machine type (should return -EINVAL)
;   - A buffer with correct structure but entry point outside any loadable segment
;     (should return -EINVAL)
;   - A valid payload (implant.bin) – expected to execute successfully and never return.
;
; Additionally, it parses the command line for the string "sealed" to enable
; the F_SEAL_WRITE flag, which is passed to load_and_exec for the valid payload.
;
; If any of the first four tests return a non‑negative value (i.e., are incorrectly
; accepted), the program exits with status 1. If the valid payload fails to execute
; (i.e., load_and_exec returns), the program also exits with status 1.
; On success, the valid payload replaces the process and the test never returns.
;
; External function:
;   - load_and_exec : defined in a previous module, expects (elf_data, size,
;                     argv, envp, seal_flags) and either executes the payload
;                     or returns a negative error code.
;
; Syscalls used:
;   - exit : terminate process (only reached on error).
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; Provides SYS_exit and flags like F_SEAL_WRITE

extern load_and_exec

section .data
    argv0 db            "implant", 0                     ; First argument (program name)
    argv  dq            argv0, 0                         ; argv array: pointer to name, null terminator
    sealed_arg db       "sealed", 0                  ; Command line option to enable sealing

section .rodata
    ; ------------------------------------------------------------------------
    ; Valid payload – embedded binary from "../payload/implant.bin"
    ; This should be a correctly formed x86‑64 ELF executable or DSO.
    ; load_and_exec will validate and execute it.
    ; ------------------------------------------------------------------------
    payload_bin incbin  "../payload/implant.bin"
    payload_len equ     $ - payload_bin

    ; ------------------------------------------------------------------------
    ; Invalid buffer #1: too small to be an ELF header (64 bytes of zeros).
    ; Should be rejected with -EINVAL.
    ; ------------------------------------------------------------------------
    invalid_buf times 64 db      0
    invalid_len equ              $ - invalid_buf

    ; ------------------------------------------------------------------------
    ; Invalid buffer #2: ELF header with wrong machine type (not EM_X86_64).
    ; This buffer is constructed as a minimal valid ELF header except for
    ; e_machine = 0 (instead of 62). It also includes a PT_LOAD segment and
    ; some trailing NOP sled to make size realistic.
    ; Should be rejected because machine type mismatch.
    ; ------------------------------------------------------------------------
    bad_machine_buf:
        ; ELF header (64 bytes)
        db 0x7F, 'E', 'L', 'F'                 ; e_ident[EI_MAG0..3]
        db 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0  ; e_ident[EI_CLASS]=2 (64‑bit),
                                                 ; EI_DATA=1 (little‑endian),
                                                 ; EI_VERSION=1, rest zero
        dw 2                                    ; e_type = ET_EXEC
        dw 0                                    ; e_machine = 0 (invalid, should be 62)
        dd 1                                    ; e_version = 1
        dq 0x400000                             ; e_entry = 0x400000 (arbitrary)
        dq 64                                    ; e_phoff = 64 (after header)
        dq 0                                     ; e_shoff = 0 (no section headers)
        dd 0                                     ; e_flags = 0
        dw 64                                    ; e_ehsize = 64
        dw 56                                    ; e_phentsize = 56
        dw 1                                     ; e_phnum = 1
        dw 0                                     ; e_shentsize = 0
        dw 0                                     ; e_shnum = 0
        dw 0                                     ; e_shstrndx = 0
        ; Program header (56 bytes) – PT_LOAD covering the code below
        times 56 db          0
        ; Overwrite the program header fields (at offset 64 from start)
        dd 1                                     ; p_type = PT_LOAD
        dd 0                                     ; p_flags = 0 (RWX? not important)
        dq 64+56                                 ; p_offset (after header + phdr)
        dq 0x400000                              ; p_vaddr = entry point
        dq 0x400000                              ; p_paddr (same)
        dq 0x100                                 ; p_filesz
        dq 0x100                                 ; p_memsz
        dq 0x1000                                ; p_align
        ; Some code (NOP sled) to fill the segment
        times 256 db         0x90
    bad_machine_len equ      $ - bad_machine_buf

    ; ------------------------------------------------------------------------
    ; Invalid buffer #3: ELF with correct machine but entry point outside
    ; any loadable segment. This tests the entry‑point validation.
    ; The header is similar to bad_machine_buf but with e_machine=62 and
    ; e_entry = 0 (outside the PT_LOAD segment at 0x400000).
    ; Should be rejected because entry point not in any loadable segment.
    ; ------------------------------------------------------------------------
    bad_entry_buf:
        db 0x7F, 'E', 'L', 'F'
        db 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
        dw 2                                    ; e_type = ET_EXEC
        dw 62                                   ; e_machine = EM_X86_64 (correct)
        dd 1                                    ; e_version = 1
        dq 0                                     ; e_entry = 0 (outside loadable segment)
        dq 64                                    ; e_phoff = 64
        dq 0                                     ; e_shoff
        dd 0                                     ; e_flags
        dw 64                                    ; e_ehsize
        dw 56                                    ; e_phentsize
        dw 1                                     ; e_phnum
        dw 0                                     ; e_shentsize
        dw 0                                     ; e_shnum
        dw 0                                     ; e_shstrndx
        ; Program header (56 bytes) – PT_LOAD at 0x400000
        times 56 db 0
        ; Overwrite program header fields
        dd 1                                     ; p_type = PT_LOAD
        dd 0                                     ; p_flags
        dq 64+56                                 ; p_offset
        dq 0x400000                              ; p_vaddr
        dq 0x400000                              ; p_paddr
        dq 0x100                                 ; p_filesz
        dq 0x100                                 ; p_memsz
        dq 0x1000                                ; p_align
        times 256 db     0x90
    bad_entry_len equ    $ - bad_entry_buf

section .text
global _start

;------------------------------------------------------------------------------
; Entry point: _start
;
; Steps:
;   1. Parse command line arguments (argc and argv from stack).
;      If the first argument (argv[1]) equals "sealed", set seal_flags = F_SEAL_WRITE.
;   2. Call load_and_exec with a null buffer and zero length (should fail).
;   3. Call load_and_exec with an undersized buffer (invalid_buf) – should fail.
;   4. Call load_and_exec with a buffer having wrong e_machine – should fail.
;   5. Call load_and_exec with a buffer whose entry point is outside any PT_LOAD – should fail.
;   6. Call load_and_exec with the valid payload, passing the seal flags.
;
; If any of the first four calls returns a non‑negative value, the test fails.
; If the valid payload call returns (i.e., fails), the test also fails.
; On success, the valid payload executes and never returns.
;------------------------------------------------------------------------------
_start:
    ; ------------------------------------------------------------------------
    ; Command line parsing: check for "sealed" argument.
    ; Stack layout at program start (Linux x86‑64):
    ;   rsp       -> argc
    ;   rsp+8     -> argv[0] (program name)
    ;   rsp+16    -> argv[1] (first argument)
    ;   ...
    ; We check if argc >= 2 and argv[1] matches "sealed" (6 characters including null).
    ; If so, set r8 = F_SEAL_WRITE, otherwise r8 = 0.
    ; ------------------------------------------------------------------------
    mov r8,      0                                    ; Default seal_flags = 0
    mov rcx,     [rsp]                               ; rcx = argc
    cmp rcx,     2                                    ; Need at least one argument besides argv0
    jl  .parse_done                               ; If less than 2, skip parsing

    mov rsi,     [rsp+16]                             ; rsi = argv[1] (pointer to first argument string)
    lea rdi,     [sealed_arg]                          ; rdi = pointer to "sealed"
    mov rcx,     6                                     ; Compare 6 bytes (including null terminator)
    repe cmpsb                                     ; Compare while equal
    jne .parse_done                                 ; If not equal, skip setting flag

    mov r8,      F_SEAL_WRITE                           ; Found "sealed" → enable write sealing

.parse_done:

    ; ------------------------------------------------------------------------
    ; Test 1: Null buffer, zero length.
    ; This should return -EINVAL (or another negative error). If it returns
    ; non‑negative, the loader is incorrectly accepting invalid input.
    ; ------------------------------------------------------------------------
    xor rdi,     rdi                                   ; buffer = NULL
    xor rsi,     rsi                                   ; size = 0
    lea rdx,     [argv]                                 ; argv
    xor rcx,     rcx                                   ; envp = NULL
    ; r8 already contains seal_flags
    call load_and_exec
    test eax,    eax                                   ; Check if return value is negative
    jns .fail                                       ; If non‑negative, fail

    ; ------------------------------------------------------------------------
    ; Test 2: Undersized buffer (64 bytes of zeros).
    ; Should return negative.
    ; ------------------------------------------------------------------------
    lea rdi,     [invalid_buf]
    mov rsi,     invalid_len
    lea rdx,     [argv]
    xor rcx,     rcx
    call load_and_exec
    test eax,    eax
    jns .fail

    ; ------------------------------------------------------------------------
    ; Test 3: Buffer with wrong machine type (e_machine != 62).
    ; Should return negative.
    ; ------------------------------------------------------------------------
    lea rdi,     [bad_machine_buf]
    mov rsi,     bad_machine_len
    lea rdx,     [argv]
    xor rcx,     rcx
    call load_and_exec
    test eax,    eax
    jns .fail

    ; ------------------------------------------------------------------------
    ; Test 4: Buffer with correct structure but entry point outside any PT_LOAD.
    ; Should return negative.
    ; ------------------------------------------------------------------------
    lea rdi,     [bad_entry_buf]
    mov rsi,     bad_entry_len
    lea rdx,     [argv]
    xor rcx,     rcx
    call load_and_exec
    test eax,    eax
    jns .fail

    ; ------------------------------------------------------------------------
    ; Test 5: Valid payload with the requested seal mask.
    ; If the payload is valid, load_and_exec will replace the current process
    ; and never return. If it returns (error), we go to .fail.
    ; ------------------------------------------------------------------------
    lea rdi,    [payload_bin]
    mov rsi,    payload_len
    lea rdx,    [argv]
    xor rcx,    rcx
    ; r8 still contains either 0 or F_SEAL_WRITE
    call load_and_exec

    ; If we reach here, the valid call failed
.fail:
    mov edi,     1                                     ; Exit status 1
    mov eax,     SYS_exit
    syscall
