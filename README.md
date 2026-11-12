# remote-ssh

让本地的 AI agent 通过 SSH 安全、可复用地操作远程服务器。

本仓库提供一个 **Agent Skill**：模型在本地运行，但真正的代码、日志和工作目录在远端服务器上。安装后，agent 可以像操作本地文件一样执行远程命令、读写远程文件，而无需在远端安装任何额外组件。

技能名称（frontmatter `name`）为 `ssh-remote`，位于仓库的 `ssh-remote/` 目录下。仓库名 `remote-ssh` 与技能名不同，安装时请把 `ssh-remote/` 子目录放到客户端的 skills 目录中。

## 特性

- **远程执行**：通过 SSH 在远端运行命令，支持管道、重定向、多行脚本
- **远程读写文件**：基于 `scp` 读取和写入远端文件，支持文本与二进制
- **连接档案**：把主机、端口、用户、工作目录集中管理，支持多台服务器
- **跨平台**：Windows（PowerShell）与 Linux/macOS（Bash）双实现
- **跨客户端**：任何能执行脚本的 agent 客户端都可使用；支持 `SKILL.md` 的客户端可直接安装为 skill
- **结构化输出**：每个包装器返回一个 JSON 对象，便于模型判断成功与否
- **多种认证**：SSH 密钥、ssh-agent，或通过环境变量提供的密码
- **非交互**：默认 `BatchMode=yes`、超时控制、输出长度上限，适合无人值守调用

## 工作原理

采用渐进式披露，避免把大量脚本内容塞进模型上下文：

1. `SKILL.md` 只包含触发条件与使用说明，仅在技能被触发时加载；
2. `scripts/` 下的包装器作为可执行代码运行，只有精简的 JSON 结果回到上下文；
3. `references/configuration.md` 等细节文档按需读取。

所有包装器都输出同一种结构：

```json
{
  "ok": true,
  "exitCode": 0,
  "stdout": "...",
  "stderr": "",
  "profile": "us_jack",
  "host": "192.168.1.10",
  "port": 22,
  "user": "jack",
  "workdir": "/home/jack",
  "authMethod": "key",
  "durationMs": 812,
  "timedOut": false
}
```

`ok` 表示包装器本身是否完成；`exitCode` 才是远端命令的退出码（`124` 表示本地超时）。

## 目录结构

```text
remote-ssh/                  # 仓库根目录（对应客户端的 skills 目录）
├── README.md
├── .gitignore
├── .gitattributes
└── ssh-remote/              # 技能目录（安装时复制这一层）
    ├── SKILL.md             # 技能说明（模型读取）
    ├── config.example.json  # 配置档案示例
    ├── references/
    │   └── configuration.md # 配置字段与认证细节
    └── scripts/
        ├── ssh-common.ps1   # PowerShell 公共库
        ├── ssh-common.sh    # Bash 公共库
        ├── ssh-profile.ps1  # 管理连接档案（Windows）
        ├── ssh-profile.sh   # 管理连接档案（Unix）
        ├── ssh-run.ps1      # 执行远程命令（Windows）
        ├── ssh-run.sh       # 执行远程命令（Unix）
        ├── ssh-file.ps1     # 读写远程文件（Windows）
        ├── ssh-file.sh      # 读写远程文件（Unix）
        └── lib/config.mjs   # Bash 版的 JSON 配置处理（Node.js）
```

## 环境要求

- 本地安装 `ssh` 和 `scp`
- Bash 版包装器需要 `node`（用于处理 JSON），PowerShell 版不依赖 Node
- 使用密码认证时：
  - Windows：需要 `plink.exe` / `pscp.exe`（PuTTY）或 `sshpass`
  - Unix：需要 `sshpass`，或使用内置的 `SSH_ASKPASS` 方案
- 推荐使用 SSH 密钥或 ssh-agent，无需额外依赖

## 安装

核心是：把仓库中的 `ssh-remote/` 子目录复制到客户端对应的 skills 目录。

### opencode（全局）

Windows：

```powershell
git clone https://github.com/vankare/remote-ssh.git "$env:TEMP\remote-ssh"
New-Item -ItemType Directory -Force "$env:USERPROFILE\.config\opencode\skills" | Out-Null
Copy-Item -Recurse -Force "$env:TEMP\remote-ssh\ssh-remote" "$env:USERPROFILE\.config\opencode\skills\ssh-remote"
Remove-Item -Recurse -Force "$env:TEMP\remote-ssh"
```

Linux/macOS：

```bash
git clone https://github.com/vankare/remote-ssh.git /tmp/remote-ssh
mkdir -p ~/.config/opencode/skills
cp -r /tmp/remote-ssh/ssh-remote ~/.config/opencode/skills/ssh-remote
rm -rf /tmp/remote-ssh
```

### opencode（项目级）

```bash
git clone https://github.com/vankare/remote-ssh.git /tmp/remote-ssh
mkdir -p <project>/.opencode/skills
cp -r /tmp/remote-ssh/ssh-remote <project>/.opencode/skills/ssh-remote
rm -rf /tmp/remote-ssh
```

### Claude Code 及其他 SKILL.md 客户端

放到对应客户端的 skills 目录即可，例如：

```bash
git clone https://github.com/vankare/remote-ssh.git /tmp/remote-ssh
mkdir -p ~/.claude/skills
cp -r /tmp/remote-ssh/ssh-remote ~/.claude/skills/ssh-remote
rm -rf /tmp/remote-ssh
```

### 不使用 skill 机制的客户端

脚本是独立的，可直接调用，例如：

```bash
bash ssh-remote/scripts/ssh-run.sh --profile us_jack --command "uname -a"
```

## 快速开始

> 以下命令均在技能目录 `ssh-remote/` 内执行。

### 1. 创建连接档案

PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ssh-profile.ps1 `
  -Action set -Name us_jack -HostName 192.168.1.10 -Port 22 -User jack `
  -WorkDir /home/jack -IdentityFile C:\Users\jack\.ssh\id_ed25519
```

Bash：

```bash
bash scripts/ssh-profile.sh set --name us_jack --host 192.168.1.10 \
  --port 22 --user jack --workdir /home/jack \
  --identity-file ~/.ssh/id_ed25519
```

查看已有档案：

```powershell
powershell -File scripts\ssh-profile.ps1 -Action list
```

```bash
bash scripts/ssh-profile.sh list
```

### 2. 执行远程命令

```powershell
powershell -File scripts\ssh-run.ps1 -Profile us_jack -Command "uname -a"
```

```bash
bash scripts/ssh-run.sh --profile us_jack --command "uname -a"
```

复杂脚本建议写入临时文件后使用 `-CommandFile` / `--command-file`，避免多层引号问题。

### 3. 读写远程文件

```powershell
# 读取
powershell -File scripts\ssh-file.ps1 -Profile us_jack -Action read -Path /home/jack/app/config.yaml

# 写入文本
powershell -File scripts\ssh-file.ps1 -Profile us_jack -Action write `
  -Path /home/jack/app/config.yaml -Content "key: value`n"

# 上传本地文件
powershell -File scripts\ssh-file.ps1 -Profile us_jack -Action write `
  -Path /home/jack/app/config.yaml -LocalFile C:\temp\config.yaml
```

```bash
bash scripts/ssh-file.sh --profile us_jack read --path /home/jack/app/config.yaml
bash scripts/ssh-file.sh --profile us_jack write --path /home/jack/app/config.yaml \
  --content $'key: value\n'
bash scripts/ssh-file.sh --profile us_jack write --path /home/jack/app/config.yaml \
  --local-file /tmp/config.yaml
```

> 文件操作基于 `scp`，不支持目录。

## 配置档案

默认位置（与客户端、技能安装目录无关）：

- Windows：`%USERPROFILE%\.config\ssh-remote\servers.json`
- Linux/macOS：`~/.config/ssh-remote/servers.json`

可通过以下方式覆盖：

- 命令行参数：`-Config <path>`（PowerShell）/ `--config <path>`（Bash）
- 环境变量：`SSH_REMOTE_CONFIG`

示例文件见 [`ssh-remote/config.example.json`](ssh-remote/config.example.json)。

### 字段说明

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `host` | 是 | IP 或域名 |
| `port` | 否 | SSH 端口，默认 `22` |
| `user` | 是 | 登录用户 |
| `workdir` | 否 | 每次执行命令前 `cd` 到的远端目录 |
| `identityFile` | 否 | 私钥路径；设置后使用密钥认证 |
| `password` | 否 | 明文密码（不推荐） |
| `passwordEnv` | 否 | 保存密码的环境变量名（推荐） |
| `connectTimeout` | 否 | 连接超时秒数，默认 `10` |
| `serverAliveInterval` | 否 | 保活间隔秒数，默认 `30` |
| `strictHostKeyChecking` | 否 | `accept-new`（默认）、`yes` 或 `no` |
| `remoteShell` | 否 | 远端 shell 命令，默认 `bash -s` |
| `hostKey` | 否 | PuTTY 的 `plink`/`pscp` 所需主机指纹 |

如果只有一档案，会自动作为默认档案；否则设置 `defaultProfile` 或显式传入档案名。

### 密码认证

推荐把密码放在环境变量里，只保存变量名：

```powershell
$env:SSH_REMOTE_PASSWORD_PROD = "your-password"
```

```bash
export SSH_REMOTE_PASSWORD_PROD="your-password"
```

然后在档案中设置 `"passwordEnv": "SSH_REMOTE_PASSWORD_PROD"`。不要提交包含明文密码的配置文件。

## 认证说明

- **密钥 / ssh-agent（推荐）**：使用 `BatchMode=yes`，不会等待输入，适合自动化。
- **密码（Windows）**：需要 `plink`/`pscp` 或 `sshpass`；`plink`/`pscp` 还需先接受主机指纹，或在档案中配置 `hostKey`。
- **密码（Unix）**：优先使用 `sshpass`，否则使用内置的 `SSH_ASKPASS` 辅助脚本。

认证失败时会返回原始 `stderr`（例如 `Permission denied (publickey)`），请据此修复密钥或改用可用的密码环境变量。

## 跨客户端共用档案

配置档案是用户级的，默认路径不包含任何客户端名称。因此：

- 同一台机器、同一个系统用户下，不同 agent 客户端调用本仓库的脚本时，会自动共用同一份档案；
- Windows 与 WSL 的 `HOME` 不同，默认不共享。可在 WSL 中把 `SSH_REMOTE_CONFIG` 指向 Windows 侧文件，例如：
  ```bash
  export SSH_REMOTE_CONFIG=/mnt/c/Users/<you>/.config/ssh-remote/servers.json
  ```
- 换机器或换系统用户后，档案不会自动跟随，需要复制，或用 `SSH_REMOTE_CONFIG` 指向同步目录。

注意：**档案与凭证是两回事**。另一处环境还需要能访问对应的私钥、ssh-agent、`known_hosts` 与 `~/.ssh/config`。

## 安全注意事项

- 不要提交 `servers.json`：本仓库的 `.gitignore` 已忽略它。
- 优先使用密钥或 `passwordEnv`，避免明文密码落入配置或日志。
- 使用最小权限的 SSH 账号；必要时通过 `sudo -n` 配合受限的 sudoers 规则。
- 保持 `StrictHostKeyChecking` 为 `accept-new` 或 `yes`，避免中间人风险。
- 定期轮换密钥与密码。

## 常见问题

**`Permission denied (publickey)`**

检查私钥路径、ssh-agent 是否已加载密钥、远端 `~/.ssh/authorized_keys` 是否正确。

**Windows 上使用密码认证时报错**

本机缺少 `plink.exe`/`pscp.exe` 或 `sshpass`。安装 PuTTY 并接受一次主机指纹，或改用密钥认证。

**Bash 版提示 `node is required`**

安装 Node.js；或改用 PowerShell 版脚本。

**文件传输失败**

`ssh-file` 基于 `scp`，只支持文件、不支持目录；确保远端路径的父目录存在且可写。

**命令超时**

默认超时 120 秒。长任务可用 `nohup ... >/tmp/job.log 2>&1 &` 后台运行后轮询，或提高 `-TimeoutSec` / `--timeout`。
