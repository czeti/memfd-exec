; syscalls.inc
; Purpose: System call numbers and constants for Linux x86-64.
; This file is included in assembly sources to provide symbolic names
; for syscall numbers and flags, improving code readability and maintainability.
; All values are architecture-specific (x86-64).

%ifndef SYSCALLS_INC
%define SYSCALLS_INC

; Syscall numbers (from Linux kernel unistd_64.h)
%define SYS_memfd_create    319   ; Create anonymous file in ram
%define SYS_exit            60    ; Terminate calling process
%define SYS_close           3     ; Close file descriptor
%define SYS_write           1     ; Write to file descriptor
%define SYS_read            0     ; Read from file descriptor
%define SYS_lseek           8     ; Reposition read/write file offset
%define SYS_fcntl           72    ; File control operations
%define SYS_execveat        322   ; Execute program relative to directory fd

; fcntl commands for file sealing (memfd-specific)
%define F_ADD_SEALS         1033  ; Add seals to memfd
%define F_SEAL_WRITE        0x0008; Prevent further writes

; execveat flags
%define AT_EMPTY_PATH       0x1000; Allow empty path to refer to fd

; memfd_create flags
%define MFD_ALLOW_SEALING   0x0002; Allow sealing operations on memfd

; Error codes (negated in syscall returns)
%define EINVAL              22    ; Invalid argument

%endif
