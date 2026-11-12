#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/ssh-common.sh"

action="${1:-list}"
if [[ $# -gt 0 ]]; then
    shift
fi

name=""
host=""
port=""
user=""
workdir=""
identity=""
password=""
password_env=""
config_arg=""

take_value() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then fail "Missing value for $1"; fi
    printf '%s' "$2"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) name=$(take_value "$@"); shift 2 ;;
        --host|--hostname) host=$(take_value "$@"); shift 2 ;;
        --port) port=$(take_value "$@"); shift 2 ;;
        --user) user=$(take_value "$@"); shift 2 ;;
        --workdir) workdir=$(take_value "$@"); shift 2 ;;
        --identity-file) identity=$(take_value "$@"); shift 2 ;;
        --password) password=$(take_value "$@"); shift 2 ;;
        --password-env) password_env=$(take_value "$@"); shift 2 ;;
        --config) config_arg=$(take_value "$@"); shift 2 ;;
        -h|--help)
            cat <<'EOF'
Usage: ssh-profile.sh set|get|list|remove|default [options]
  --name NAME              Profile name
  --host HOST              SSH host
  --port PORT              SSH port (default 22)
  --user USER              SSH user
  --workdir DIR            Remote working directory
  --identity-file PATH     SSH identity file
  --password PASS          Password (prefer --password-env)
  --password-env NAME      Environment variable holding the password
  --config PATH            Config file path
EOF
            exit 0
            ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

config=$(resolve_config_path "$config_arg")
require_node

case "$action" in
    set)
        if [[ -z "$name" ]]; then fail "Provide --name."; fi
        if [[ -z "$host" ]]; then fail "Provide --host."; fi
        if [[ -z "$user" ]]; then fail "Provide --user."; fi
        updates=$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' node -e '
            const args = process.argv.slice(1);
            const output = {};
            for (let i = 0; i < args.length - 1; i += 2) {
                const key = args[i];
                const value = args[i + 1];
                if (value !== "") output[key] = value;
            }
            process.stdout.write(JSON.stringify(output));
        ' host "$host" port "$port" user "$user" workdir "$workdir" identityFile "$identity" passwordEnv "$password_env" password "$password")
        if ! out=$(node "$LIB_DIR/config.mjs" set "$config" "$name" "$updates" 2>&1); then fail "$out"; fi
        printf '{"ok":true,"action":"set","name":%s,"configPath":%s}\n' "$(json_str "$name")" "$(json_str "$config")"
        ;;
    get)
        if [[ -z "$name" ]]; then fail "Provide --name."; fi
        if ! out=$(node "$LIB_DIR/config.mjs" get "$config" "$name" 2>&1); then fail "Profile '$name' not found in $config"; fi
        printf '{"ok":true,"action":"get","name":%s,"configPath":%s,"data":%s}\n' "$(json_str "$name")" "$(json_str "$config")" "$out"
        ;;
    list)
        if ! out=$(node "$LIB_DIR/config.mjs" list "$config" 2>&1); then fail "$out"; fi
        printf '{"ok":true,"action":"list","configPath":%s,"data":%s}\n' "$(json_str "$config")" "$out"
        ;;
    remove)
        if [[ -z "$name" ]]; then fail "Provide --name."; fi
        if ! out=$(node "$LIB_DIR/config.mjs" remove "$config" "$name" 2>&1); then fail "Profile '$name' not found in $config"; fi
        printf '{"ok":true,"action":"remove","name":%s,"configPath":%s}\n' "$(json_str "$name")" "$(json_str "$config")"
        ;;
    default)
        if [[ -z "$name" ]]; then fail "Provide --name."; fi
        if ! out=$(node "$LIB_DIR/config.mjs" default "$config" "$name" 2>&1); then fail "Profile '$name' not found in $config"; fi
        printf '{"ok":true,"action":"default","name":%s,"configPath":%s}\n' "$(json_str "$name")" "$(json_str "$config")"
        ;;
    *)
        fail "Unknown action: $action"
        ;;
esac
