#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/ssh-common.sh"

action=""
path=""
content=""
has_content=false
content_file=""
local_file=""
encoding="utf8"
binary=false

profile=""
host=""
port=""
user=""
identityFile=""
password=""
passwordEnv=""
host_override=""
port_override=""
user_override=""
identity_override=""
password_override=""
password_env_override=""
config_arg=""
timeout_sec=120

take_value() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then fail "Missing value for $1"; fi
    printf '%s' "$2"
}

take_value_allow_empty() {
    if [[ $# -lt 2 ]]; then fail "Missing value for $1"; fi
    printf '%s' "$2"
}

decode_base64() {
    if base64 --decode </dev/null >/dev/null 2>&1; then
        base64 --decode
    else
        base64 -D
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        read|write) action="$1"; shift ;;
        --action) action=$(take_value "$@"); shift 2 ;;
        --path) path=$(take_value "$@"); shift 2 ;;
        --content) content=$(take_value_allow_empty "$@"); has_content=true; shift 2 ;;
        --content-file) content_file=$(take_value "$@"); shift 2 ;;
        --local-file) local_file=$(take_value "$@"); shift 2 ;;
        --encoding) encoding=$(take_value "$@"); shift 2 ;;
        --binary) binary=true; shift ;;
        --profile) profile=$(take_value "$@"); shift 2 ;;
        --host|--hostname) host_override=$(take_value "$@"); shift 2 ;;
        --port) port_override=$(take_value "$@"); shift 2 ;;
        --user) user_override=$(take_value "$@"); shift 2 ;;
        --identity-file) identity_override=$(take_value "$@"); shift 2 ;;
        --password) password_override=$(take_value "$@"); shift 2 ;;
        --password-env) password_env_override=$(take_value "$@"); shift 2 ;;
        --config) config_arg=$(take_value "$@"); shift 2 ;;
        --timeout) timeout_sec=$(take_value "$@"); shift 2 ;;
        -h|--help)
            cat <<'EOF'
Usage: ssh-file.sh [options] read|write --path PATH
  --action read|write       Action (or pass read/write as the first positional)
  --path PATH               Remote file path
  --content TEXT            Content to write
  --content-file PATH       Local file containing content to write
  --local-file PATH         Local file to upload directly
  --encoding utf8|base64    Content encoding (default utf8)
  --binary                  Shorthand for --encoding base64
  --profile NAME            Profile name from the config
  --host HOST               Override host
  --port PORT               Override port (default 22)
  --user USER               Override user
  --identity-file PATH      Override SSH identity file
  --password PASS           Password (prefer --password-env)
  --password-env NAME       Environment variable holding the password
  --config PATH             Config file path
  --timeout SECONDS         Local timeout (default 120)
EOF
            exit 0
            ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

if [[ "$action" != "read" && "$action" != "write" ]]; then
    fail "Provide read or write (for example: ssh-file.sh read --path /etc/os-release)."
fi
if [[ -z "$path" ]]; then
    fail "Provide --path."
fi
if [[ "$encoding" != "utf8" && "$encoding" != "base64" ]]; then
    fail "Invalid --encoding: $encoding"
fi
if [[ "$binary" == "true" ]]; then
    encoding="base64"
fi
use_base64=false
if [[ "$encoding" == "base64" ]]; then
    use_base64=true
fi

config=$(resolve_config_path "$config_arg")
load_profile "$config" "$profile"

[[ -n "$host_override" ]] && host="$host_override"
[[ -n "$port_override" ]] && port="$port_override"
[[ -n "$user_override" ]] && user="$user_override"
[[ -n "$identity_override" ]] && identityFile="$identity_override"

resolve_password "$password_override" "$password_env_override"
validate_connection

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/ssh-remote.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
scp_out="$tmpdir/scp.out"
scp_err="$tmpdir/scp.err"

scp_bin=$(find_cmd scp)
if [[ -z "$scp_bin" ]]; then fail "scp executable not found."; fi

scp_args=(-P "$port")
while IFS= read -r opt; do scp_args+=("$opt"); done < <(base_ssh_options)
if [[ -n "$identityFile" ]]; then scp_args+=(-i "$identityFile" -o IdentitiesOnly=yes); fi
if [[ -n "$PASSWORD_VALUE" ]]; then
    scp_args+=(-o BatchMode=no)
else
    scp_args+=(-o BatchMode=yes)
fi

if [[ "$action" == "read" ]]; then
    download="$tmpdir/download.bin"
    scp_args+=("$user@$host:$path" "download.bin")
    exec_remote "" "$scp_out" "$scp_err" "$timeout_sec" "$tmpdir" "$scp_bin" "${scp_args[@]}"
    code=$?
    if (( code != 0 )); then
        printf '{"ok":false,"action":"read","path":%s,"exitCode":%d,"stderr":%s,"authMethod":%s,"error":%s}\n' \
            "$(json_str "$path")" "$code" "$(json_str_file "$scp_err")" "$(json_str "$AUTH_METHOD")" "$(json_str "scp failed")"
        exit 1
    fi
    size=$(wc -c <"$download" | tr -d ' ')
    if [[ "$use_base64" == "true" ]]; then
        content_json=$(json_str "$(base64 <"$download" | tr -d '\n\r')")
        encoding_out="base64"
    else
        content_json=$(json_str_file "$download")
        encoding_out="utf8"
    fi
    printf '{"ok":true,"action":"read","path":%s,"encoding":%s,"bytes":%d,"content":%s,"authMethod":%s}\n' \
        "$(json_str "$path")" "$(json_str "$encoding_out")" "$size" "$content_json" "$(json_str "$AUTH_METHOD")"
    exit 0
fi

upload="$tmpdir/upload.bin"
if [[ -n "$local_file" ]]; then
    if [[ ! -f "$local_file" ]]; then fail "Local file not found: $local_file"; fi
    cp "$local_file" "$upload"
elif [[ -n "$content_file" ]]; then
    if [[ ! -f "$content_file" ]]; then fail "Content file not found: $content_file"; fi
    if [[ "$use_base64" == "true" ]]; then
        decode_base64 <"$content_file" >"$upload"
    else
        cp "$content_file" "$upload"
    fi
elif [[ "$has_content" == "true" ]]; then
    if [[ "$use_base64" == "true" ]]; then
        printf '%s' "$content" | decode_base64 >"$upload"
    else
        printf '%s' "$content" >"$upload"
    fi
else
    fail "Provide --content, --content-file, or --local-file."
fi

size=$(wc -c <"$upload" | tr -d ' ')
scp_args+=("upload.bin" "$user@$host:$path")
exec_remote "" "$scp_out" "$scp_err" "$timeout_sec" "$tmpdir" "$scp_bin" "${scp_args[@]}"
code=$?
if (( code != 0 )); then
    printf '{"ok":false,"action":"write","path":%s,"exitCode":%d,"stderr":%s,"authMethod":%s,"error":%s}\n' \
        "$(json_str "$path")" "$code" "$(json_str_file "$scp_err")" "$(json_str "$AUTH_METHOD")" "$(json_str "scp failed")"
    exit 1
fi
printf '{"ok":true,"action":"write","path":%s,"bytes":%d,"authMethod":%s}\n' \
    "$(json_str "$path")" "$size" "$(json_str "$AUTH_METHOD")"
