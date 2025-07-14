.text
.global _start
// The code here does a weird thing of 
// storing the return address in %r15
// This avoids pushing to stack (which is page aligned, so this matters a lot),
// and is in general faster. The choise of %r15 is because the sysV abi says %r15
// is callee preserved, meaning it can be set before entering a loop, and sysV
// code (which includes syscalls) will not disturb it.
_start:
    // grow the stack by 4096 and align to 4096
    movq %rsp, %rbp
    movq $-4096, %rax
    andq %rax, %rsp
    addq %rax, %rsp
    // argc -> %rcx
    movq (%rbp), %rcx
    // envp - 1 -> %rdx
    leaq 8(%rbp, %rcx, 8), %rdx

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
    // %rbp, %rsp occupied with stack
    // %rbx - sliced PATH
    // %r12 - start of fd buffer
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
    // never will. But since we're testing the return code anyways, this
    // only adds 1 instruction and 1 byte.
    movq %rax, %rdx
    shrq $32, %rax
    jnz .fail

    subq $4, %r12
    movl %edx, (%r12)
    addq $1, %rbx
    cmpb $':', -1(%rbx)
    je .Ltop
    
    // execve to argc[1] with argc[1..] and envp[..]
    leaq 16(%rbp), %rsi
    movq 16(%rbp), %rdi
    movq (%rbp), %rdx
    leaq 16(%rbp, %rdx, 8), %rdx
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
    // Could assume exit never fails and remove the `hlt`
    // This would then allow deduplicating the `syscall`
    // This would save a total of 3 bytes (WOW!)
.checked_syscall:
    syscall
    cmpq $-4096, %rax
    ja .fail
    jmp *%r15
