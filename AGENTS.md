# AGENTS.md

**Read `CLAUDE.md` first** — it is the operating guide for this repo (commands, working-directory
requirements, RTL/notebook conventions, naming gotchas). Then read `docs/Process.md`, which is
the single source of truth for research status, numerical contracts, and results.

Everything in those two files applies to you. This file only adds environment notes specific to
running as a sandboxed agent on this machine.

## Python on this machine

Call Python through an **absolute path to a real interpreter**:

```
C:/Users/harry/AppData/Local/Programs/Python/Python313/python.exe
```

Do **not** use `python3`, and do **not** use `uv` to provision an interpreter.

Why: `python3` on this box resolves to `C:\Users\harry\AppData\Local\Microsoft\WindowsApps\python3`,
which is a Microsoft Store *App Execution Alias* — a reparse point. It works in an unrestricted
shell, but under a sandboxed agent's filesystem policy executing it fails with
`存取被拒 / permission denied (os error 5)`. Falling back to `uv` does not help either: the
trampoline at `C:\Users\harry\.local\bin\python3.14.exe` hits the same error when it tries to
spawn its Python child process, and `uv python install` then fails because it cannot write
outside the workspace.

This silently costs you every verification step that depends on Python. If a task asks you to
regenerate `gen_pattern.py` output or run a cross-check script and Python is unavailable,
**say so explicitly in your report** rather than reporting the task as verified.

`C:/Users/harry/AppData/Local/Programs/Python/Python310/python.exe` also exists if 3.13 causes
a problem.

## No EDA tools locally

VCS, Design Compiler, and the TSMC libraries are on the server, not here. Do not attempt to run
`01_run` / `02_run` / `03_run` or invoke `vcs` / `dc_shell` locally. Verify what you can in
Python and state plainly what remains unverified.
