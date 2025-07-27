//! Registers preserved across syscalls:
//! - %rsp: stack pointer
//! - %rbp: base pointer (our stack is variable sized, no getting around this)
//! - %rbx: free use
//! - %r12: free use
//! - %r13: free use
//! - $r14: (input fd) << 32 | (output fd)
//! - %r15: allocated for (launcher mode?) << 8 | (separator byte)
.text
/// Find the path variable and skip "PATH="
/// Input:
///   %rbx - envp
///   %rdi - chain pointer
/// Output:
///   %rax - clobbered
///   %rbx - pointer to PATH contents
1:
    addq $8, %rbx
.find_path:
    movq (%rbx), %rax
    testq %rax, %rax
    jz .fail
    cmpb $'P', (%rax)
    jne 1b
    cmpb $'A', 1(%rax)
    jne 1b
    cmpb $'T', 2(%rax)
    jne 1b
    cmpb $'H', 3(%rax)
    jne 1b
    cmpb $'=', 4(%rax)
    jne 1b
    leaq 5(%rax), %rbx
    jmp *%rdi
/// Copy the next directory in path.
/// Input:
///   %rax - first character of path, not 0
///   %rbx - points into path
///   %rdx - output pointer (assumed to be in stack, checked against %rbp)
///   %rdi - chain pointer
/// Output:
///   %rax - clobbered
///   %rbx - points past read part of path or the null terminator
///   %rdx - points to the output null terminator
/// Only registers in the output section are modified
///
.next_dir:
    cmpq %rdx, %rbp
    je .fail
    addq $1, %rbx
    cmpb $':', %al
    je 1f
    movb %al, (%rdx)
    movzbl (%rbx), %eax
    addq $1, %rdx
    testb %al, %al
    jnz .next_dir
1:
    movb $0, (%rdx)
    jmp *%rdi
/// Copy string to stack buffer.
/// Input:
///   %rcx - input pointer
///   %rdx - output pointer (assumed to be in stack, checked against %rbp)
///   %rdi - chain pointer
/// Output:
///   %rax - clobbered
///   %rcx - points to the input null terminator
///   %rdx - points to the output null terminator
1:
    leaq 1(%rcx), %rcx
    leaq 1(%rdx), %rdx
.strcopy:
    cmpq %rdx, %rbp
    je .fail
    movzbl (%rcx), %eax
    movb %al, (%rdx)
    testb %al, %al
    jnz 1b
    jmp *%rdi

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

    movl $'\n', %r15d
    cmpq $2, %rax
    jb .Larg_handler_end

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
    setne %r15b
    shll $8, %r15d
    jmp .Larg_handler_end
.Llf_with_child:
    movl $('\n' + 256), %r15d
.Larg_handler_end:

    // go straight to .print if not in launcher mode
    movl $1, %r14d
    movl %r15d, %eax
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

    // prepare to call `.exec`
    leaq 16(%rbp), %r14
    leaq 24(%rbp), %rcx
    // if separator is \0, then skip the additional "-0" argument
    testb %r14b, %r14b
    cmovz %rcx, %r14

    movq %rsp, %rbx
    jmp .exec

.print_pipe_setup:
    // pipes are stored such that:
    // - %ebx is child read half
    // - (%rbx) >> 32 is parent write half
    // - %r12d is parent read half
    // - (%r12) >> 32 is child write half
    // We need to close the child fds and set up %r14

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

    // we need %r14 = (%r12d << 32) | (%rbx >> 32)
    movl %r12d, %r14d
    shrq $32, %rbx
    shlq $32, %r14
    orq %rbx, %r14
.print:


    // exit if no child
    movl %r15d, %eax
    xorl %edi, %edi
    shrl $8, %eax
    jz .exit

    // close write half, set %r13 to read half
    movl %r14d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    shrq $32, %r14

    jmp .Lwait_start
.Lwait:
    // WIFEXITED(status) = ((status & 0x7f) == 0)
    // WEXITSTATUS(status) = ((status & 0xff00) >> 8)
    // We're testing for successful exit, so
    // status & 0x7f == 0 and (status & 0xff00) >> 8 == 0
    // which is equivalent to (status & 0xff7f == 0)
    testw $0xff7f, (%rsp)
    jnz .fail
.Lwait_start:
    // wait4(-1, (%rsp), 0, 0)
    movq $-1, %rdi
    movq %rsp, %rsi
    xorl %edx, %edx
    xorl %r10d, %r10d
    movl $61, %eax
    syscall
    cmpq $-4096, %rax
    jbe .Lwait

    movq %rsp, %rbx
.Lread_loop:
    movl %r14d, %edi
    movq %rbp, %rdx
    movq %rbx, %rsi
    subq %rbx, %rdx
    xorl %eax, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    addq %rax, %rbx
    testq %rax, %rax
    jnz .Lread_loop

    // close read half
    movl %r14d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // validate selection
    cmpq %rsp, %rbx
    je .fail
    cmpb %r15b, -1(%rbx)
    jne .fail
    movq %rsp, %rax
.Lpast_sep_loop:
    addq $1, %rax
    cmpb %r15b, -1(%rax)
    jne .Lpast_sep_loop
    // had more than one separator?
    cmpq %rbx, %rax
    jne .fail

    movb $0, -1(%rax)

    // set up argv
    movq %rsp, 8(%rbp)
    movq $0, 16(%rbp)
    leaq 8(%rbp), %r14

    // Assumes:
    // - %r14 is argv
    // - the memory in [%rbx, %rbp) is not referenced by the arguments
.exec:
    movq (%r14), %r12
    movq %rbx, %r13
    // envp -> %rbx
    movq (%rbp), %rax
    leaq 16(%rbp, %rax, 8), %rbx
    // start by trying as absolute path
    movq %r12, %rdi
    movq %r14, %rsi
    movq %rbx, %rdx
    movl $59, %eax
    syscall

    movq %rbx, %r15
    // Try from $PATH
    movl $.Lfound_path, %edi
    jmp .find_path
.Lfound_path:
    // set up .next_dir arguments
    movzbl (%rbx), %eax
    testb %al, %al
    jz .fail
    movq %r13, %rdx
    movl $.Lappend_name, %edi
    jmp .next_dir
.Lappend_name:
    cmpq %rdx, %rbp
    je .fail
    movb $'/', (%rdx)
    addq $1, %rdx
    // set up .strcopy arguments
    movq %r12, %rcx
    movl $.Lname_assembled, %edi
    jmp .strcopy
.Lname_assembled:
    movq %r13, %rdi
    movq %r14, %rsi
    movq %r15, %rdx
    movl $59, %eax
    syscall
    jmp .Lfound_path

.fail:
    movl $1, %edi
.exit:
    movl $60, %eax
    syscall
    // exit failed, hlt (stops the CPU if ring 0, otherwise death)
    hlt
