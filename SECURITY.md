# Security policy

LaunchBrake is a self-control and friction tool, not a security boundary. A user
who can edit their own files can remove its shims, edit its plaintext state, run
an executable by absolute path, or use an uncovered runtime-specific launcher.
Those intentional escape hatches are not security vulnerabilities.

Please report issues that allow unintended command execution, modify unrelated
user files, corrupt state during normal use, or bypass a launch surface that
appblock explicitly reports as enforced. Open a private GitHub security advisory
for command-execution or destructive-file issues; use a normal issue for other
bugs.

Never include private paths, URLs, or state-file contents without redacting them.
