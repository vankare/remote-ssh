# SSH Remote configuration

Profiles live in a single JSON file. The default path is:

- Windows: `%USERPROFILE%\.config\ssh-remote\servers.json`
- Linux/macOS: `~/.config/ssh-remote/servers.json`

Override it with `-Config <path>` / `--config <path>` or the
`SSH_REMOTE_CONFIG` environment variable. This location is independent of the
agent client and of the skill install directory, so the same profiles can be
reused across clients. Keeping the file outside the project avoids committing
passwords and host details.

## File shape

```json
{
  "defaultProfile": "dev",
  "profiles": {
    "dev": {
      "host": "192.168.1.10",
      "port": 22,
      "user": "jack",
      "workdir": "/home/jack/app",
      "identityFile": "C:\\Users\\jack\\.ssh\\id_ed25519"
    }
  }
}
```

## Profile fields

| Field | Required | Meaning |
| --- | --- | --- |
| `host` | yes | IP address or DNS name |
| `port` | no | SSH port, default `22` |
| `user` | yes | SSH user |
| `workdir` | no | Directory every command `cd`s into first |
| `identityFile` | no | Private key path; enables key auth |
| `password` | no | Plaintext password (avoid; prefer `passwordEnv`) |
| `passwordEnv` | no | Name of an environment variable holding the password |
| `connectTimeout` | no | SSH connect timeout in seconds, default `10` |
| `serverAliveInterval` | no | Keepalive interval in seconds, default `30` |
| `strictHostKeyChecking` | no | `accept-new` (default), `yes`, or `no` |
| `remoteShell` | no | Remote shell command, default `bash -s` |
| `hostKey` | no | PuTTY host key fingerprint for `plink`/`pscp` |

If both `password` and `passwordEnv` are present, `passwordEnv` wins. When
using a password, set the environment variable before calling the wrapper, for
example:

```powershell
$env:SSH_REMOTE_PASSWORD_DEV = "secret"
```

```bash
export SSH_REMOTE_PASSWORD_DEV="secret"
```

## Auth behavior

- Key auth uses `BatchMode=yes`; it never prompts.
- Windows password auth uses `plink.exe`/`pscp.exe` (PuTTY) or `sshpass`.
  `plink`/`pscp` need the host key accepted once, or `hostKey` set.
- Unix password auth uses `sshpass` when available, otherwise OpenSSH's
  `SSH_ASKPASS` helper.
- File transfers use `scp`; directories are not supported.

## Managing profiles

Windows:

```powershell
powershell -File scripts\ssh-profile.ps1 -Action set -Name dev `
  -HostName 192.168.1.10 -Port 22 -User jack -WorkDir /home/jack/app `
  -IdentityFile C:\Users\jack\.ssh\id_ed25519
powershell -File scripts\ssh-profile.ps1 -Action list
```

Bash:

```bash
bash scripts/ssh-profile.sh set --name dev --host 192.168.1.10 --port 22 \
  --user jack --workdir /home/jack/app --identity-file ~/.ssh/id_ed25519
bash scripts/ssh-profile.sh list
```
