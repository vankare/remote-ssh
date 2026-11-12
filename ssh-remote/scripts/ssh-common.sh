#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
DEFAULT_CONFIG="${SSH_REMOTE_CONFIG:-$HOME/.config/ssh-remote/servers.json}"
PASSWORD_VALUE=""
AUTH_METHOD=""

json_str() {
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
        node -e 'process.stdout.write(JSON.stringify(process.argv[1] || ""))' "$1"
}

json_str_file() {
    node -e 'const fs=require("fs");process.stdout.write(JSON.stringify(fs.readFileSync(process.argv[1],"utf8")))' "$1"
}

fail() {
    printf '{"ok":false,"error":%s}\n' "$(json_str "$1")"
    exit 1
}

require_node() {
    if ! command -v node >/dev/null 2>&1; then
        fail "node is required for the Bash wrappers."
    fi
}

resolve_config_path() {
    local config="${1:-}"
    if [[ -n "$config" ]]; then
        printf '%s' "$config"
    elif [[ -n "${SSH_REMOTE_CONFIG:-}" ]]; then
        printf '%s' "$SSH_REMOTE_CONFIG"
    else
        printf '%s' "$DEFAULT_CONFIG"
    fi
}

load_profile() {
    local config="$1" name="${2:-}"
    require_node
    local output
    if [[ -n "$name" ]]; then
        if ! output=$(node "$LIB_DIR/config.mjs" export "$config" "$name" 2>&1); then
            fail "Profile '$name' not found in $config"
        fi
    else
        output=$(node "$LIB_DIR/config.mjs" export "$config" "" 2>/dev/null) || true
    fi
    eval "$output"
}

find_cmd() {
    command -v "$1" 2>/dev/null || true
}

exec_remote() {
    local stdin_file="$1" stdout_file="$2" stderr_file="$3" timeout_sec="$4" workdir="$5"
    shift 5
    local exe="$1"
    shift

    local -a timeout_cmd=()
    if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
        timeout_cmd=(timeout "$timeout_sec")
    elif command -v gtimeout >/dev/null 2>&1; then
        timeout_cmd=(gtimeout "$timeout_sec")
    fi

    local -a cmd=()
    local askpass=""
    AUTH_METHOD="key"
    if [[ -n "$PASSWORD_VALUE" ]]; then
        local sshpass
        sshpass=$(find_cmd sshpass)
        if [[ -n "$sshpass" ]]; then
            cmd=("$sshpass" -p "$PASSWORD_VALUE")
            AUTH_METHOD="sshpass"
        else
            askpass=$(mktemp "${TMPDIR:-/tmp}/ssh-remote-askpass.XXXXXX")
            printf '#!/bin/sh\nprintf "%%s\\n" "$SSH_REMOTE_PASSWORD"\n' >"$askpass"
            chmod 700 "$askpass"
            export SSH_ASKPASS="$askpass"
            export SSH_ASKPASS_REQUIRE=force
            export DISPLAY="${DISPLAY:-:0}"
            export SSH_REMOTE_PASSWORD="$PASSWORD_VALUE"
            AUTH_METHOD="askpass"
        fi
    fi

    cmd+=("$exe" "$@")
    if [[ -n "$workdir" ]]; then
        if [[ -n "$stdin_file" ]]; then
            ( cd -- "$workdir" && "${timeout_cmd[@]+"${timeout_cmd[@]}"}" "${cmd[@]}" <"$stdin_file" >"$stdout_file" 2>"$stderr_file" )
        else
            ( cd -- "$workdir" && "${timeout_cmd[@]+"${timeout_cmd[@]}"}" "${cmd[@]}" </dev/null >"$stdout_file" 2>"$stderr_file" )
        fi
    elif [[ -n "$stdin_file" ]]; then
        "${timeout_cmd[@]+"${timeout_cmd[@]}"}" "${cmd[@]}" <"$stdin_file" >"$stdout_file" 2>"$stderr_file"
    else
        "${timeout_cmd[@]+"${timeout_cmd[@]}"}" "${cmd[@]}" </dev/null >"$stdout_file" 2>"$stderr_file"
    fi
    local code=$?

    if [[ -n "$askpass" ]]; then
        rm -f "$askpass"
    fi
    return $code
}

resolve_password() {
    local cli_password="${1:-}" cli_password_env="${2:-}"
    PASSWORD_VALUE=""
    if [[ -n "$cli_password" ]]; then
        PASSWORD_VALUE="$cli_password"
    elif [[ -n "$cli_password_env" ]]; then
        PASSWORD_VALUE="${!cli_password_env:-}"
        if [[ -z "$PASSWORD_VALUE" ]]; then
            fail "Environment variable '$cli_password_env' is empty or not set."
        fi
    elif [[ -n "${password:-}" ]]; then
        PASSWORD_VALUE="$password"
    elif [[ -n "${passwordEnv:-}" ]]; then
        PASSWORD_VALUE="${!passwordEnv:-}"
        if [[ -z "$PASSWORD_VALUE" ]]; then
            fail "Environment variable '$passwordEnv' is empty or not set."
        fi
    fi
}

validate_connection() {
    if [[ -z "${host:-}" ]]; then
        fail "No host configured. Pass --profile or --host."
    fi
    if [[ -z "${user:-}" ]]; then
        fail "No user configured. Pass --user or add it to the profile."
    fi
    port="${port:-22}"
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        fail "Invalid port: $port"
    fi
}

base_ssh_options() {
    printf '%s\n' \
        "-o" "ConnectTimeout=${connectTimeout:-10}" \
        "-o" "ServerAliveInterval=${serverAliveInterval:-30}" \
        "-o" "StrictHostKeyChecking=${strictHostKeyChecking:-accept-new}"
}

write_remote_script() {
    local destination="$1" command="$2" no_workdir="$3"
    {
        if [[ "$no_workdir" != "true" ]]; then
            local dir="${workdir:-}"
            if [[ -n "$dir" ]]; then
                local quoted
                quoted=$(printf '%q' "$dir")
                printf 'cd -- %s || { printf "ssh-remote: cannot cd to %%s\\n" %s >&2; exit 125; }\n' "$quoted" "$quoted"
            fi
        fi
        printf '%s' "$command"
        if [[ "$command" != *$'\n' ]]; then
            printf '\n'
        fi
    } >"$destination"
}
