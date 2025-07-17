.text
.global _start
_start:
    // grow the stack by 4096 and align to 4096
    movq %rsp, %rbp
    movq $-4096, %rax
    andq %rax, %rsp
    addq %rax, %rsp
    // argc -> %r15, which is not destroyed by syscalls
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
    // Note: the buffer is intentionally shrunk, so that later we have stack
    // space for stat/getdents64 syscall structures. With the current file name
    // size limit of 255 chars + '\0', stat + getdents64 need at least 419
    // bytes, but writes may go up to 3 bytes before the buffer, so we need at
    // least 422 bytes. I like 512, so that's what I chose.
    leaq 512(%rsp), %rdx
.Linner:
    // path didn't fit into buffer
    cmpq %r12, %rdx
    jae .fail
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

    // open(%rsp, O_DIRECTORY | O_CLOEXEC, 0)
    leaq 512(%rsp), %rdi
    movl $0x90000, %esi
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

    // .Lprint uses %r13d as write half, %r13 >> 32 as read half
    // sets write half to 1 for stdout, and set upper bits to 0 for stdin
    movl $1, %r13d
    // comparing against %r13 would be 1 byte smaller,
    // but would introduce a dependency
    cmpq $1, %r15
    jbe .Lprint

    // must preserve %rsp for stack
    // must preserve %rbp and %r12 for dirfd array
    // must preserve %r15 for argc
    // %r12-15, %rsp, %rbp, %rbx are preserved across syscalls
    // so, we can still use %r13 and %r14 to save 4 pipes (2 fds per register)
    // %rbx stays free for now (was used previously for PATH)

    // do first pipe
    movq %rsp, %rdi
    movl $22, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    movq (%rsp), %r13
    // do second pipe
    movq %rsp, %rdi
    movl $22, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    movq (%rsp), %r14

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
    // NOTE: %r15 is not modified in the child code path, so it's still argc
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
    //   - r13d has pipe 1 read half
    //   - r13 >> 32 has pipe 1 write half
    //   - r14d has pipe 2 read half
    //   - r14 >> 32 has pipe 2 write half
    // pipe 1 is for parent -> child
    // pipe 2 is for child -> parent

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

    // we need to set %r13d to our write half, and %r13 >> 32 to our read half
    // AKA %r13 top half -> %r13d, $r14d -> %r13 upper half
    movl %r14d, %eax
    shrq $32, %r13
    shlq $32, %rax
    orq %rax, %r13
.Lprint:
    // Since I'm considering adding a -0 option, put the separator in %r14
    movl $'\n, %r14d

    /* this is the structure that getdents64 writes
    struct linux_dirent64 {
        // 64-bit, not needed
        ino64_t d_ino;
        // 64-bit, not needed
        off64_t d_off;
        // the lenght of this dirent
        unsigned short d_reclen; // 16 byte offset
        // entry type
        unsigned char d_type; // 18 byte offset
        // null terminated name (of size d_reclen - 19)
        char d_name[]; // 19 byte offset
    };
    */

    // %r12 is occupied with dirfd array
    // %r13 has the write and read fds
    // %r14 is occupied with the separator
    // %rsp, %rbp are for the stack
    // This leaves %rbx, %r15
    // finally, we do getdents64/write loop
    movq %rbp, %r15
    // "shrink" the stack to allow using offsets in the range [-128, 127],
    // which allows for much shorter offset encodings
    // for optimal shrinkage, we need `a` and `b`,
    //     such that a < 127, b < 127, a + b = 144
    // one such pair is 72 and 72.
    // We write 72 bytes below %rsp, but that's in the redzone.
    addq $72, %rsp
.Lgetdents:
    movl -4(%r15), %edi
    leaq -72(%r12), %rdx
    subq %rsp, %rdx
    leaq 72(%rsp), %rsi
    movl $217, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    testq %rax, %rax
    jz .Lgetdents_next_dir
    // We only have %rbx left, but we need 2 register.
    // Luckily, the ino64_t at 72(%rsp)
    movq %r12, 72(%rsp)
    movq %rax, %r12
    leaq 72(%rsp), %rbx
.Lstat_loop:
    movzbl 18(%rbx), %eax
    // x & ~8 == 0 iff (x == 0 || x == 8)
    testb $-9, %al
    jz .Ldo_stat
    cmpb $10, %al
    jne .Lstat_end
.Ldo_stat:
    movl -4(%r15), %edi
    leaq 19(%rbx), %rsi
    leaq -72(%rsp), %rdx
    xorl %r10d, %r10d
    movl $262, %eax
    syscall
    testq %rax, %rax
    jnz .fail
    // get st_mode at offset 24 (24 - 72 = -48)
    movl -48(%rsp), %eax
    // test if (st_mode & (S_IXUSR | S_IFMT)) == (S_IXUSR | S_IFREG)
    andl $0xf040, %eax
    cmpl $0x8040, %eax
    jne .Lstat_end

    // start preparing for write
    movzwl 16(%rbx), %eax
    // the name is up to 27 bytes shorter than the struct
    // do name_size -= min(dirent_size, 28)
    subl $28, %eax
    movl $0, %edx
    cmovnc %eax, %edx
    // actually strlen + 1
.Lstrlen:
    addl $1, %edx
    cmpb $0, -1(%rsi, %rdx)
    jne .Lstrlen
.Lstrlen_end:
    movb %r14b, -1(%rsi, %rdx)
    movl %r13d, %edi
    leaq 19(%rbx), %rsi
    movl $1, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail

.Lstat_end:
    movzwl 16(%rbx), %eax
    addq %rax, %rbx
    subq %rax, %r12
    jnz .Lstat_loop
    // restore %r12 from the unused ino64_t
    movq 72(%rsp), %r12
    jmp .Lgetdents
.Lgetdents_next_dir:
    subq $4, %r15
    cmpq %r15, %r12
    jne .Lgetdents

    // set %r15 back to argc
    movq (%rbp), %r15
    // if argc <= 1, exit right away
    xorl %edi, %edi
    cmpq $1, %r15
    jbe .exit

    // restore the stack
    addq $-72, %rsp

    // close our write half, so that the other process can get EOF
    movl %r13d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
    // currently our read half is in %r13 >> 32, put it in %r13d
    shrq $32, %r13

    // set %rbx to the remaining stack capacity and start reading
    movq %r12, %rbx
    subq %rsp, %rbx
.Lread_child:
    movl %r13d, %edi
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
    // close read half
    movl %r13d, %edi
    movl $3, %eax
    syscall
    cmpq $-4096, %rax
    ja .fail
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
    // wait4(-1, (%rsp), 0, 0)
    movq $-1, %rdi
    movq %rbp, %rsi
    xorl %edx, %edx
    xorl %r10d, %r10d
    movl $61, %eax
    syscall
    cmpq $-4096, %rax
    jbe .Lwait

    xorl %edi, %edi
    jmp .exit
