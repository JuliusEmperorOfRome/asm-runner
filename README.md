# Listing executables in $PATH

`$ ./asm-runner`

That's it.
When run without arguments, it lists all files that the **user** can execute.

# Launcher mode

`$ ./asm-runner command [args]..`

In short, it uses `command [args]..` to select a file to execute.

More precisely, when asm-runner has arguments, it will spawn command with all
arguments passed to it. It will then pass its output to the command, read the
command's output. If the command exits successfully and the command's output
contains exactly one newline as its last character, asm-runner will try to exec
into the command named by the command's output.

# BUGS

Because of a [bug in execveat][1], asm-runner fails to launch interpreted
programs (mostly meaning scripts starting with `#!`).


[1]: <https://manpages.debian.org/unstable/manpages-dev/execveat.2.en.html#ENOENT>
