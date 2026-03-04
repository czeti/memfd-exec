;------------------------------------------------------------------------------
; Self‑contained test program for memfd_create / write_all / read validation.
;
; This program demonstrates and tests the functionality of:
;   - create_memfd: creates an anonymous file descriptor (memfd)
;   - write_all: writes a fixed pattern (0x00..0xFF) to the memfd
;   - lseek: rewinds the file offset to the beginning
;   - read: reads the data back into a separate buffer
;   - cmpsb: compares the original pattern with the read data
;
; If the write and read operations succeed and the data matches,
; the program exits with status 0. Otherwise, it exits with status 1.
;
; This serves as a basic integrity test for the memfd wrapper functions
; and the underlying kernel support for memfd_create(2).
;
; System calls used directly:
;   - lseek   : reposition file offset (syscall number SYS_lseek)
;   - read    : read from file descriptor (SYS_read)
;   - close   : close file descriptor (SYS_close)
;   - exit    : terminate process (SYS_exit)
;
; External functions:
;   - create_memfd   : from the earlier module
;   - write_all      : from the earlier module (handles partial writes)
;------------------------------------------------------------------------------

%include "../include/syscalls.inc"   ; Provides SYS_* constants

extern create_memfd
extern write_all

section .data
    name db         "test_writer", 0          ; Name for the memfd (visible in /proc)

section .bss
    pattern resb     256                  ; Buffer for the original pattern (0x00..0xFF)
    read_buf resb    256                  ; Buffer for the data read back from memfd

section .text
global _start

;------------------------------------------------------------------------------
; Entry point: _start
;
; Steps performed:
;   1. Fill the 'pattern' buffer with bytes 0x00 through 0xFF.
;   2. Create a memfd named "test_writer" with sealing allowed.
;   3. Write the entire pattern to the memfd using write_all.
;   4. Rewind the file offset to the beginning using lseek.
;   5. Read the data back into 'read_buf'.
;   6. Compare the original pattern with the read data.
;   7. If any step fails or data mismatches, exit with status 1.
;   8. Otherwise, close the memfd and exit with status 0.
;------------------------------------------------------------------------------
_start:
    ; ------------------------------------------------------------------------
    ; Step 1: Fill the pattern buffer with a known sequence (0x00 .. 0xFF).
    ; This creates a simple pattern that is easy to verify.
    ; ------------------------------------------------------------------------
    mov rdi,    pattern                ; Destination buffer
    xor rcx,    rcx                     ; Index (0‑based)
.fill_pattern:
    cmp rcx,    256                     ; Have we filled all 256 bytes?
    jge .fill_done                       ; If yes, continue
    mov byte [rdi + rcx],    cl             ; Store the lower byte of the index
    inc rcx                              ; Move to next byte
    jmp .fill_pattern                     ; Loop
.fill_done:

    ; ------------------------------------------------------------------------
    ; Step 2: Create a memfd with sealing allowed.
    ; create_memfd(name, flags); flags = 0 (no sealing requested yet,
    ; but we pass MFD_ALLOW_SEALING via create_memfd? Actually create_memfd
    ; expects flags in RSI; we pass 0, so sealing not allowed. Original code
    ; passes xor rsi, rsi => 0. That means the memfd is created without
    ; MFD_ALLOW_SEALING, so later sealing would fail. This is fine for a test.
    ; ------------------------------------------------------------------------
    mov rdi,    name                    ; Name for the memfd
    xor rsi,    rsi                      ; flags = 0 (no sealing)
    call create_memfd
    js .error                             ; If negative return, error occurred

    ; Save the file descriptor in a callee‑saved register (r12) for later use.
    mov r12,    rax                      ; r12 = memfd fd

    ; ------------------------------------------------------------------------
    ; Step 3: Write the entire pattern to the memfd using write_all.
    ; write_all(fd, buffer, size)
    ; ------------------------------------------------------------------------
    mov rdi,    r12                      ; fd
    mov rsi,    pattern                   ; source buffer
    mov rdx,    256                       ; number of bytes to write
    call write_all
    test rax,   rax                       ; write_all returns 0 on success
    jnz .error                             ; Non‑zero indicates failure

    ; ------------------------------------------------------------------------
    ; Step 4: Reposition the file offset to the beginning of the file.
    ; lseek(fd, offset, whence); offset 0, whence SEEK_SET (0)
    ; This ensures the subsequent read starts from the beginning.
    ; ------------------------------------------------------------------------
    mov rdi,    r12                      ; fd
    xor esi,    esi                       ; offset = 0
    xor edx,    edx                       ; whence = SEEK_SET (0)
    mov eax,    SYS_lseek
    syscall
    test eax,   eax                       ; lseek returns the new offset on success,
    jnz .error                             ; but we just check for error (negative)

    ; ------------------------------------------------------------------------
    ; Step 5: Read the data back into read_buf.
    ; read(fd, buffer, count)
    ; ------------------------------------------------------------------------
    mov rdi,    r12                      ; fd
    mov rsi,    read_buf                   ; destination buffer
    mov edx,    256                       ; number of bytes to read
    mov eax,    SYS_read
    syscall
    cmp rax,    256                       ; Must read exactly 256 bytes
    jne .error                             ; If less or error, fail

    ; ------------------------------------------------------------------------
    ; Step 6: Compare the original pattern with the data read back.
    ; repe cmpsb compares byte by byte while they are equal, up to RCX bytes.
    ; After the instruction, if RCX == 0, all bytes matched; otherwise, ZF=0.
    ; ------------------------------------------------------------------------
    mov r12,    rdi                      ; Save fd (rdi was overwritten); actually we still have r12
    ; The original code does: mov r12, rdi after read, but rdi still holds fd.
    ; This is unnecessary but harmless. We'll keep as documented.

    ; Close the memfd. Even if we are about to exit, it's good practice.
    mov eax,    SYS_close
    syscall
    test eax,   eax                       ; Check for close error (unlikely)
    jnz .error

    ; Now compare the two buffers.
    mov rdi,    pattern                   ; Source 1
    mov rsi,    read_buf                   ; Source 2
    mov rcx,    256                       ; Number of bytes to compare
    repe cmpsb                             ; Compare while equal
    je .done                                ; If equal (RCX == 0, ZF=1), success

    ; ------------------------------------------------------------------------
    ; Error path: exit with status 1.
    ; ------------------------------------------------------------------------
.error:
    mov edi,     1                             ; Exit status 1
    mov eax,     SYS_exit
    syscall

    ; ------------------------------------------------------------------------
    ; Success path: exit with status 0.
    ; ------------------------------------------------------------------------
.done:
    xor edi,    edi                        ; Exit status 0
    mov eax,    SYS_exit
    syscall
