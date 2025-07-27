# Usage

`asm-runner` has two main modes of operation, described below.

## List $PATH mode

`$ ./asm-runner [-0]`

Lists all files in `$PATH` that the user can execute, separated by newlines (`\n`).
With `-0`, the output is separated with NUL (`\0`) instead. Executables for which
the user doesn't have appropriate permissions will not be listed.

## Launcher mode

`$ ./asm-runner [-0] command [args]..`

`asm-runner` uses `command [args]..` as a selector program. The selector receives
the output of [List $PATH mode](#list_path_mode) on its stdin, and outputs the
selection on its stdout. Then `asm-runner` checks that the selector exited
successfully, the selection isn't empty and has exactly one separator, which is at
the end. If the selection passses these checks, it is executed. By default the
separator is newline, or NUL if `-0` was passed.
