%include "include/syscalls.inc"

section .text
global _start
_start:
    mov edi,    42
    mov eax,    SYS_exit
    syscall
