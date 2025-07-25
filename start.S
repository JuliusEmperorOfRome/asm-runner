/// Registers preserved across syscalls:
/// - %rsp: stack pointer
/// - %rbp: base pointer (our stack is variable sized, no getting around this)
/// - $r13: (input fd) << 32 | (output fd)
/// - %r14: allocated for (launcher mode?) << 8 | (separator byte)
/// - %r15: allocated for $PATH pointer (without "PATH=")
/// - %rbx: free use
/// - %r12: free use
.text
.global _start
_start:
    // get argc
    movq (%rsp), %rax
    // set base pointer
    movq %rsp, %rbp
    // Grow our stack to a page boundary (hopefully)
    movq $-4096, %rdx
    addq %rdx, %rsp
    andq %rdx, %rsp

    movl $'\n', %r14d
    cmpq $2, %rax
    jb .Lfind_path

    // is argv[1] == "-0"?
    movq 16(%rbp), %rdx
    cmpb $'-', (%rdx)
    jne .Llf_with_child
    cmpb $'0', 1(%rdx)
    jne .Llf_with_child
    cmpb $0, 2(%rdx)
    jne .Llf_with_child

    // %r14 = (argc != 2) << 8
    cmpq $2, %rax
    setne %r14b
    shll $8, %r14d
    jmp .Lfind_path
.Llf_with_child:
    movl $('\n' + 256), %r14d

.Lfind_path:
    // %r14 is set, %rax is argc
    // envp - 1 -> %rax
    leaq 8(%rbp, %rax, 8), %rax
.Lfind_top:
    addq $8, %rax
    // loading directly to %r14 would add a byte to every instruction, not cool
    movq (%rax), %rdx
    testq %rdx, %rdx
    jz .fail
    cmpb $'P', (%rdx)
    jne .Lfind_top
    cmpb $'A', 1(%rdx)
    jne .Lfind_top
    cmpb $'T', 2(%rdx)
    jne .Lfind_top
    cmpb $'H', 3(%rdx)
    jne .Lfind_top
    cmpb $'=', 4(%rdx)
    jne .Lfind_top
    cmpb $0, 5(%rdx)
    je .fail
    addq $5, %rdx
    movq %rdx, %r15

    // go straight to .print if not in launcher mode
    movl $1, %r13d
    movl %r14d, %eax
    shrl $8, %eax
    jz .print

    movq %rsp, %rdi
    movl $22, %eax
    syscall
    testq %rax, %rax
    jnz .fail
    movq (%rsp), %rbx

    movq %rsp, %rdi
    movl $22, %eax
    syscall
    testq %rax, %rax
    jnz .fail
    movq (%rsp), %r12

    // fork
    movl $57, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    testq %rax, %rax
    jnz .print_pipe_setup

    // pipes are stored such that:
    // - %ebx is child read half
    // - (%rbx) >> 32 is parent write half 
    // - %r12d is parent read half
    // - (%r12) >> 32 is child write half 
    // We need to close parent fds, and remap stdin/stdout

    movl %r12d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    movq %rbx, %rdi
    shrq $32, %rdi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // remap stdin
    movl %ebx, %edi
    xorl %esi, %esi
    movl $33, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    movl %ebx, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // remap stdout
    movq %r12, %rdi
    shrq $32, %rdi
    movl $1, %esi
    movl $33, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    movq %r12, %rdi
    shrq $32, %rdi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // prepare to fall into `.exec`
    leaq 16(%rbp), %r14
    leaq 24(%rbp), %rcx
    // if separator is \0, then skip the additional "-0" argument
    testb %r14b, %r14b
    cmovz %rcx, %r14

    movq %rsp, %rbx

    // Assumes:
    // - %r14 is argv
    // - %r15 points to the contents of $PATH (AKA after "PATH=")
    // - the memory in [%rbx, %rbp) is not referenced by the arguments
.exec:
    // envp -> %r13
    movq (%rbp), %rax
    leaq 16(%rbp, %rax, 8), %r13
    // start by trying as absolute path
    movq (%r14), %rdi
.Lrestart_exec:
    movq %r14, %rsi
    movq %r13, %rdx
    movl $59, %eax
    syscall

    movzbl (%r15), %eax
    testb %al, %al
    jz .fail
    movq %rbx, %rdx
.Lcopydir:
    cmpq %rdx, %rbp
    je .fail
    addq $1, %r15
    cmpb $':', %al
    je .Lcopyname
    movb %al, (%rdx)
    addq $1, %rdx

    movzbl (%r15), %eax
    testb %al, %al
    jnz .Lcopydir

.Lcopyname:
    // name pointer -> %rcx
    movq (%r14), %rcx
.Lcopyname_loop:
    cmpq %rdx, %rbp
    je .fail
    movzbl (%rcx), %eax
    movb %al, (%rdx)
    addq $1, %rcx
    addq $1, %rdx
    testb %al, %al
    jnz .Lcopyname_loop

    movq %rbx, %rdi
    jmp .Lrestart_exec

.fail:
    movl $1, %edi
.exit:
    movl $60, %eax
    syscall
    // exit failed, hlt (stops the CPU if ring 0, otherwise death)
    hlt
.print_pipe_setup:
    // pipes are stored such that:
    // - %ebx is child read half
    // - (%rbx) >> 32 is parent write half 
    // - %r12d is parent read half
    // - (%r12) >> 32 is child write half 
    // We need to close the child fds and set up %r13

    movl %ebx, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    movq %r12, %rdi
    shrq $32, %rdi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // we need %r13 = (%r12d << 32) | (%rbx >> 32)
    movl %r12d, %r13d
    shrq $32, %rbx
    shlq $32, %r13
    orq %rbx, %r13
.print:
    // exit if no child
    movl %r14d, %eax
    xorl %edi, %edi
    shrl $8, %eax
    jz .exit

    // close write half, set %r13 to read half
    movl %r13d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    shrq $32, %r13

    jmp .Lwait_start
.Lwait:
    // WIFEXITED(status) = ((status & 0x7f) == 0)
    // WEXITSTATUS(status) = ((status & 0xff00) >> 8)
    // We're testing for successful exit, so
    // status & 0x7f == 0 and (status & 0xff00) >> 8 == 0
    // which is equivalent to (status & 0xff7f == 0)
    testw $0xff7f, (%rbp)
    jnz .fail
.Lwait_start:
    // wait4(-1, (%rbp), 0, 0)
    movq $-1, %rdi
    movq %rbp, %rsi
    xorl %edx, %edx
    xorl %r10d, %r10d
    movl $61, %eax
    syscall
    cmpq $-4096, %rax
    jbe .Lwait 

    // TODO: read selection

    // close read half
    movl %r13d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    xorl %edi, %edi
    jmp .exit
