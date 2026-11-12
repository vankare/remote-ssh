---
name: ssh-remote
description: Run shell commands and read/write files on a remote server over SSH when the agent client is local but the working directory lives on the server. Use this skill whenever the user mentions SSH, a server IP/host, port, username, SSH profile, a remote working directory, or asks to run commands, inspect logs, edit files, deploy, or troubleshoot on a remote Linux/Unix machine. Trigger it for Chinese requests like 登录服务器、在服务器上运行、远程执行、查看服务器日志、修改服务器上的文件、ssh 到某台机器. Use it even when the user does not explicitly say "SSH". Do not use it for purely local commands.
compatibility: Requires ssh and scp on the local machine. Password auth additionally needs plink/pscp (PuTTY) or sshpass on Windows, or sshpass (or SSH_ASKPASS) on Unix.
---

# SSH Remote

Use the bundled wrappers to execute commands and transfer files on a remote
server. The local `read`, `edit`, `grep`, and `glob` tools only see the local
filesystem; they cannot see the server. When the user's real working directory
is on the server, use this skill instead of the local file tools.

All script paths below are relative to this skill's base directory. Resolve
them to absolute paths before invoking.

## Core rule

Never guess a server's contents. Run a command with `ssh-run` or read a file
with `ssh-file`, then act on the returned JSON. Every wrapper prints one JSON
object and exits `0` when it produced a result (even if the remote command
failed). Check `ok`, `exitCode`, `stdout`, and `stderr`.

## Step 1: Resolve the connection profile

Profiles live in `~/.config/ssh-remote/servers.json` by default (on Windows,
`%USERPROFILE%\.config\ssh-remote\servers.json`). Override this with `-Config`
(`--config`) or the `SSH_REMOTE_CONFIG` environment variable. Use `ssh-profile`
to create, inspect, or update them. Never invent connection details.

If the user has not provided connection details, ask for:

- host (IP or DNS name)
- port (default `22`)
- user
- remote working directory (the directory all commands should run in)
- auth: an SSH key path, or a password (prefer an environment variable)

Then save a profile. Prefer key auth. For password auth, pass `-PasswordEnv`
(`--password-env` on Bash) so the secret stays in the environment instead of
the config file.

Windows (PowerShell):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ssh-profile.ps1" `
  -Action set -Name dev -HostName 192.168.1.10 -Port 22 -User jack `
  -WorkDir /home/jack/app -IdentityFile C:\Users\jack\.ssh\id_ed25519
```

Bash (Linux/macOS):

```bash
bash "<skill>/scripts/ssh-profile.sh" set --name dev --host 192.168.1.10 \
  --port 22 --user jack --workdir /home/jack/app \
  --identity-file ~/.ssh/id_ed25519
```

List profiles with `-Action list` / `list`. If exactly one profile exists it is
used by default; otherwise set `defaultProfile` or pass the profile name.

## Step 2: Run a command

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ssh-run.ps1" `
  -Profile dev -Command "uname -a"
```

Bash:

```bash
bash "<skill>/scripts/ssh-run.sh" --profile dev --command "uname -a"
```

For multi-line scripts or anything with complex quoting, write the script to a
local temp file and pass `-CommandFile` / `--command-file`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ssh-run.ps1" `
  -Profile dev -CommandFile C:\Users\jack\AppData\Local\Temp\task.sh
```

```bash
bash "<skill>/scripts/ssh-run.sh" --profile dev --command-file /tmp/task.sh
```

The wrapper sends the script to the remote shell over stdin, so pipes,
redirections, heredocs, `&&`, and quotes work normally. Commands run in the
profile's `workdir` by default. Use `-NoWorkDir` / `--no-workdir` to run from
the login directory, or `-WorkDir` / `--workdir` to override it once.

Result shape:

```json
{
  "ok": true,
  "exitCode": 0,
  "stdout": "...",
  "stderr": "",
  "profile": "dev",
  "host": "192.168.1.10",
  "port": 22,
  "user": "jack",
  "workdir": "/home/jack/app",
  "authMethod": "key",
  "durationMs": 812,
  "timedOut": false,
  "stdoutTruncated": false,
  "stderrTruncated": false
}
```

`ok` is `true` when the wrapper itself completed. `exitCode` is the remote
command's exit code (`124` means the local timeout fired). When `ok` is `false`,
read `error` and explain it to the user; do not retry blindly.

## Step 3: Read or write a remote file

Read text:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ssh-file.ps1" `
  -Profile dev -Action read -Path /home/jack/app/config.yaml
```

```bash
bash "<skill>/scripts/ssh-file.sh" --profile dev read --path /home/jack/app/config.yaml
```

Write text from a string:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ssh-file.ps1" `
  -Profile dev -Action write -Path /home/jack/app/config.yaml -Content "key: value`n"
```

Upload a local file (safer for large or binary content):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\ssh-file.ps1" `
  -Profile dev -Action write -Path /home/jack/app/config.yaml -LocalFile C:\temp\config.yaml
```

```bash
bash "<skill>/scripts/ssh-file.sh" --profile dev write \
  --path /home/jack/app/config.yaml --local-file /tmp/config.yaml
```

For binary reads, add `-Binary` / `--binary` (or `-Encoding base64`). The
result contains `content` as base64. For binary writes, pass a `-LocalFile` or
base64 `-Content` with `-Encoding base64`. File operations use `scp` under the
hood and do not support directories.

## Auth rules

- Prefer SSH keys or `ssh-agent`. Key auth uses `BatchMode=yes` and never
  prompts.
- Password auth is non-interactive:
  - Windows: commands require `plink.exe` (PuTTY) or `sshpass`; file transfers
    require `pscp.exe` (PuTTY) or `sshpass`. `plink`/`pscp` also need the host
    key accepted once, or a `hostKey` in the profile.
  - Unix: uses `sshpass` when available, otherwise the built-in `SSH_ASKPASS`
    helper.
- Never print, echo, or write a password into a command, log, or the final
  answer. Prefer `passwordEnv` over a plaintext `password` field.
- If auth fails, report the exact `stderr` (for example
  `Permission denied (publickey)`) and ask the user to fix the key or provide a
  password environment variable. Do not loop on retries.

## Non-interactive execution

There is no TTY. Avoid editors, pagers, and prompts:

- `sudo -n` instead of `sudo`
- `apt-get -y`, `dnf -y`, `npm ci --yes`, `--no-pager` for `git`/`systemctl`
- `ssh -T`-style commands only
- For long jobs, use `nohup ... >/tmp/job.log 2>&1 &` and then poll with
  `tail`/`cat` in later calls, or raise `-TimeoutSec` / `--timeout`.

The default timeout is 120 seconds. Output is capped at 1,000,000 characters
per stream; when `stdoutTruncated` or `stderrTruncated` is true, narrow the
command (for example `tail -n 200`) instead of asking for the whole file.

The PowerShell wrapper always enforces the timeout. The Bash wrapper uses GNU
`timeout` or `gtimeout`; if neither is installed (for example in a minimal Git
Bash on Windows), it still runs the command but cannot enforce the limit. Use
the PowerShell wrapper when a hard timeout matters on Windows.

## Working effectively

- Treat the server as the source of truth. Before editing, read the file with
  `ssh-file` or `sed -n` through `ssh-run`.
- For edits, prefer a scripted, reviewable change (write a temp file and move it
  into place, or use `sed -i` with a backup) over many tiny commands.
- Batch related checks into one `ssh-run` call to save round trips, but keep
  commands readable.
- When a command fails, read `stderr` and `exitCode` first; only then decide
  whether to change the command or the profile.
- Report the remote `exitCode` to the user when it matters, and quote the
  relevant `stdout`/`stderr` instead of paraphrasing errors.

## Reference

See `references/configuration.md` for every profile field and the exact config
file layout.
