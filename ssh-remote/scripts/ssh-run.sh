#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/ssh-common.sh"

profile=""
host=""
port=""
user=""
workdir=""
identityFile=""
remoteShell=""
password=""
passwordEnv=""
host_override=""
port_override=""
user_override=""
workdir_override=""
identity_override=""
password_override=""
password_env_override=""
remote_shell_override=""
config_arg=""
no_workdir=false
timeout_sec=120
max_output=1000000
command=""
command_file=""
has_command=false

take_value() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then fail "Missing value for $1"; fi
    printf '%s' "$2"
}

take_value_allow_empty() {
    if [[ $# -lt 2 ]]; then fail "Missing value for $1"; fi
    printf '%s' "$2"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) profile=$(take_value "$@"); shift 2 ;;
        --host|--hostname) host_override=$(take_value "$@"); shift 2 ;;
        --port) port_override=$(take_value "$@"); shift 2 ;;
        --user) user_override=$(take_value "$@"); shift 2 ;;
        --workdir) workdir_override=$(take_value "$@"); shift 2 ;;
        --no-workdir) no_workdir=true; shift ;;
        --identity-file) identity_override=$(take_value "$@"); shift 2 ;;
        --password) password_override=$(take_value "$@"); shift 2 ;;
        --password-env) password_env_override=$(take_value "$@"); shift 2 ;;
        --config) config_arg=$(take_value "$@"); shift 2 ;;
        --remote-shell) remote_shell_override=$(take_value "$@"); shift 2 ;;
        --timeout) timeout_sec=$(take_value "$@"); shift 2 ;;
        --max-output) max_output=$(take_value "$@"); shift 2 ;;
        --command) command=$(take_value_allow_empty "$@"); has_command=true; shift 2 ;;
        --command-file) command_file=$(take_value "$@"); shift 2 ;;
        -h|--help)
            cat <<'EOF'
Usage: ssh-run.sh [options]
  --profile NAME          Profile name from the config
  --host HOST             Override host
  --port PORT             Override port (default 22)
  --user USER             Override user
  --workdir DIR           Override remote working directory
  --no-workdir            Do not cd into a remote working directory
  --identity-file PATH    Override SSH identity file
  --password PASS         Password (prefer --password-env)
  --password-env NAME     Environment variable holding the password
  --config PATH           Config file path
  --remote-shell SHELL    Remote shell command (default "bash -s")
  --timeout SECONDS       Local timeout (default 120)
  --max-output CHARS      Max characters per stream (default 1000000)
  --command COMMAND       Remote command
  --command-file PATH     Read the remote command from a local file
EOF
            exit 0
            ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

if [[ -n "$command_file" ]]; then
    if [[ ! -f "$command_file" ]]; then fail "Command file not found: $command_file"; fi
    command=$(cat "$command_file")
    has_command=true
fi
if [[ "$has_command" != "true" ]]; then
    fail "Provide --command or --command-file."
fi

config=$(resolve_config_path "$config_arg")
load_profile "$config" "$profile"

[[ -n "$host_override" ]] && host="$host_override"
[[ -n "$port_override" ]] && port="$port_override"
[[ -n "$user_override" ]] && user="$user_override"
[[ -n "$workdir_override" ]] && workdir="$workdir_override"
[[ -n "$identity_override" ]] && identityFile="$identity_override"
[[ -n "$remote_shell_override" ]] && remoteShell="$remote_shell_override"

resolve_password "$password_override" "$password_env_override"
validate_connection

if ! [[ "$timeout_sec" =~ ^[0-9]+$ ]] || (( timeout_sec < 1 )); then fail "Invalid --timeout: $timeout_sec"; fi
if ! [[ "$max_output" =~ ^[0-9]+$ ]] || (( max_output < 1 )); then fail "Invalid --max-output: $max_output"; fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/ssh-remote.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
script_file="$tmpdir/script.sh"
outfile="$tmpdir/out"
errfile="$tmpdir/err"

write_remote_script "$script_file" "$command" "$no_workdir"

ssh_bin=$(find_cmd ssh)
if [[ -z "$ssh_bin" ]]; then fail "ssh executable not found."; fi

ssh_args=(-p "$port")
while IFS= read -r opt; do ssh_args+=("$opt"); done < <(base_ssh_options)
if [[ -n "$identityFile" ]]; then ssh_args+=(-i "$identityFile" -o IdentitiesOnly=yes); fi
target="$user@$host"
read -r -a shell_args <<<"${remoteShell:-bash -s}"
if [[ -n "$PASSWORD_VALUE" ]]; then
    ssh_args+=(-o BatchMode=no)
else
    ssh_args+=(-o BatchMode=yes)
fi
ssh_args+=(-- "$target" "${shell_args[@]}")

started=$(date +%s)
exec_remote "$script_file" "$outfile" "$errfile" "$timeout_sec" "" "$ssh_bin" "${ssh_args[@]}"
code=$?
elapsed=$(( ($(date +%s) - started) * 1000 ))

out_size=$(wc -c <"$outfile" | tr -d ' ')
err_size=$(wc -c <"$errfile" | tr -d ' ')
stdout_truncated=false
stderr_truncated=false
if (( out_size > max_output )); then
    head -c "$max_output" "$outfile" >"$outfile.cut"
    mv "$outfile.cut" "$outfile"
    stdout_truncated=true
fi
if (( err_size > max_output )); then
    head -c "$max_output" "$errfile" >"$errfile.cut"
    mv "$errfile.cut" "$errfile"
    stderr_truncated=true
fi

stdout_json=$(json_str_file "$outfile")
stderr_json=$(json_str_file "$errfile")
profile_json=null
if [[ -n "$profile" ]]; then profile_json=$(json_str "$profile"); fi
workdir_out=""
if [[ "$no_workdir" != "true" ]]; then workdir_out="$workdir"; fi
workdir_json=null
if [[ -n "$workdir_out" ]]; then workdir_json=$(json_str "$workdir_out"); fi
timed_out=false
if (( code == 124 )); then timed_out=true; fi

printf '{"ok":true,"exitCode":%d,"stdout":%s,"stderr":%s,"profile":%s,"host":%s,"port":%s,"user":%s,"workdir":%s,"authMethod":%s,"durationMs":%d,"timedOut":%s,"stdoutTruncated":%s,"stderrTruncated":%s}\n' \
    "$code" "$stdout_json" "$stderr_json" "$profile_json" "$(json_str "$host")" "$port" "$(json_str "$user")" "$workdir_json" "$(json_str "$AUTH_METHOD")" "$elapsed" "$timed_out" "$stdout_truncated" "$stderr_truncated"
