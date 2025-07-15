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
    // don't fail instantly, maybe the user messed up permissions in their PATH
    jnz .Lcontinue

    subq $4, %r12
    movl %edx, (%r12)
.Lcontinue:
    addq $1, %rbx
    cmpb $':', -1(%rbx)
    je .Ltop

    // couldn't open anything in PATH
    cmpq %r12, %rbp
    je .fail

    // skip pipe/fork/execve if argc <= 1
    // .Lprint uses %r13 as the write fd and %r14 as the read fd
    movl $1, %r13d
    xorl %r14d, %r14d
    cmpq $1, %r15
    jbe .Lprint

    // must preserve %rsp for stack
    // must preserve %rbp and %r12 for dirfd array
    // must preserve %r15 for argc
    // %r12-15, %rsp, %rbp, %rbx are preserved across syscalls
    // so, we can still use %r13 and %r14 to save 4 pipes (2 fds per register)
    // %rbx stays free for now (was used previously for PATH)

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

    // sysV x64 is little endian, so:
    //   - r13d has pipe 1 read half
    //   - r13 >> 32 has pipe 1 write half
    //   - r14d has pipe 2 read half
    //   - r14 >> 32 has pipe 2 write half
    // pipe 1 is for parent -> child
    // pipe 2 is for child -> parent

    // fork
    movl $57, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    testq %rax, %rax
    jnz .Lprint_pipes

    // This is the child process

    // close(pipe 1 write half)
    movq %r13, %rdi
    shrq $32, %rdi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // close(pipe 2 read half)
    movl %r14d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // move the pipe 2 write half to %r14d
    shrq $32, %r14

    // dup2(pipe 1 read half, 0)
    movl %r13d, %edi
    xorl %esi, %esi
    movl $33, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // dup2(pipe 2 write half, 1)
    movl %r14d, %edi
    movl $1, %esi
    movl $33, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // close old fds
    movl %r13d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    movl %r14d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // %r13 and %r14 are finally free.
    leaq 16(%rbp), %r13
    leaq 16(%rbp, %r15, 8), %r14

    // tries to execveat into PATH dirs with argv in %r13 and envp in %r14
    // Notably, if pathname is absolute, then execveat ignores dirfd,
    // effectively doing an execve.
.execve:
    // %rbx points right after the dirfd to use
    movq %rbp, %rbx
.Lexecveat:
    movl -4(%rbx), %edi
    movq %r13, %rdx
    movq %r14, %r10
    movq (%r13), %rsi
    xorl %r8d, %r8d
    movl $322, %eax
    syscall
    // try next dirfd, if we can
    subq $4, %rbx
    cmpq %rbx, %r12
    jne .Lexecveat
.fail:
    // set exit code
    movl $1, %edi
.exit:
    // exit is syscall 60
    movl $60, %eax
    syscall
    hlt
.Lprint_pipes:
    // close(%r13d), which is pipe 1 read half
    movl %r13d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    // close(%r14 >> 32), which is pipe 2 write half
    movq %r14, %rdi
    shrq $32, %rdi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // set %r13 to our write fd
    shrq $32, %r13
    // set %r14 to our read fd
    movl %r14d, %r14d
.Lprint:
    // %r12-15 are occupied, %rbx is the last register that syscalls don't clobber
    // Since I'm considering adding a -0 option, put the separator in (%rbp)
    movl $'\n, (%rbp)

    // TODO: do the actual printing

    // if argc <= 1, exit right away
    xorl %edi, %edi
    cmpq $1, %r15
    jbe .exit

    // close our write half, so that the other process can get EOF (%r13 is freed)
    movl %r13d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

    // set %rbx to the remaining stack capacity and start reading
    movq %r12, %rbx
    subq %rsp, %rbx
.Lread_child:
    movl %r14d, %edi
    movq %r12, %rsi
    subq %rbx, %rsi
    movq %rbx, %rdx
    xorl %eax, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    // EOF
    testq %rax, %rax
    jz .Lafter_reads
    // filled buffer
    cmpq %rbx, %rax
    je .Lafter_reads

    subq %rax, %rbx
    jmp .Lread_child


.Lafter_reads:

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

    xorl %edi, %edi
    jmp .exit
