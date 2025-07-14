.text
.global _start
_start:
    // grow the stack by 4096 and align to 4096
    movq %rsp, %rbp
    movq $-4096, %rax
    andq %rax, %rsp
    addq %rax, %rsp
    // argc -> %r15, which is not destroyed by syscalls (this program never writes to it again)
    movq (%rbp), %r15
    // envp - 1 -> %rdx
    leaq 8(%rbp, %r15, 8), %rdx

    // find 'PATH='
.Lpath_loop:
    addq $8, %rdx
    movq (%rdx), %rax
    testq %rax, %rax
    jz .fail
    cmpb $'P', (%rax)
    jne .Lpath_loop
    cmpb $'A', 1(%rax)
    jne .Lpath_loop
    cmpb $'T', 2(%rax)
    jne .Lpath_loop
    cmpb $'H', 3(%rax)
    jne .Lpath_loop
    cmpb $'=', 4(%rax)
    jne .Lpath_loop

    // (%rax) == "PATH=..."
    leaq 5(%rax), %rbx

    cmpb $0, (%rbx)
    // PATH was empty
    je .fail

    // this loop opens path directories to the range (%r12)..(%rbp)
    movq %rbp, %r12
.Ltop:
    // load buffer start
    movq %rsp, %rdx
.Linner:
    // path didn't fit into buffer
    cmpq %rdx, %r12
    je .fail
    movzbl (%rbx), %eax
    cmpb $':', %al
    je .Lopen
    testb %al, %al
    je .Lopen
    addq $1, %rbx
    movb %al, (%rdx)
    addq $1, %rdx
    jmp .Linner
.Lopen:
    // trailing 0
    movb $0, (%rdx)

    // open(%rsp, O_DIRECTORY | O_PATH | O_CLOEXEC, 0)
    movq %rsp, %rdi
    movl $0x290000, %esi
    xorl %edx, %edx
    movl $2, %eax
    syscall
    // the current kernel ABI doesn't allow 64bit fds, and will most likely
    // never will. But since we're testing the return code anyways, checking 
    // that only adds 1 instruction and 1 byte.
    movq %rax, %rdx
    shrq $32, %rax
    jnz .fail

    subq $4, %r12
    movl %edx, (%r12)
    addq $1, %rbx
    cmpb $':', -1(%rbx)
    je .Ltop
    
    // skip pipe/fork/execve if argc <= 1
    cmpq $1, %r15
    jbe .Lprint

    // must preserve %rsp for stack
    // must preserve %rbp and %r12 for dirfd array
    // must preserve %r15 for argc
    // %r12-15, %rsp, %rbp, %rbx are preserved across syscalls
    // so, we can still use %r13 and %r14 to save 4 pipes (2 fds per register)

    // Note: (%rbp) stored argc, we overwrite it. This is why keeping %r15 is important
    // do first pipe
    movq %rbp, %rdi
    movl $22, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    movq (%rbp), %r13
    // do second pipe
    movq %rbp, %rdi
    movl $22, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    movq (%rbp), %r14

    // fork
    movl $57, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    testq %rax, %rax
    jnz .Lprint

    // This is the child process

    // execve to argc[1] with argc[1..] and envp[..]
    leaq 16(%rbp), %rsi
    movq 16(%rbp), %rdi
    leaq 16(%rbp, %r15, 8), %rdx
    movl $59, %eax
    syscall

.fail:
    // set exit code
    movl $1, %edi
.exit:
    // exit is syscall 60
    movl $60, %eax
    syscall
    hlt
.Lprint:

    // repeat wait4(-1,null,0,null) until it fails
.Lwait:
    movq $-1, %rdi
    xorl %esi, %esi
    xorl %edx, %edx
    xorl %r10d, %r10d
    movl $61, %eax
    syscall
    cmpq $-4096, %rax
    jbe .Lwait

    xorl %eax, %eax
    jmp .exit
