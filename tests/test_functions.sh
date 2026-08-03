#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install_caddy_emby.sh
source "$ROOT_DIR/install_caddy_emby.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

validate_domain "emby.example.com" || fail "valid domain rejected"
! validate_domain "https://emby.example.com" || fail "URL accepted as domain"

normalize_backend "127.0.0.1:8096" || fail "IPv4 backend rejected"
[[ "$NORMALIZED_BACKEND" == "127.0.0.1:8096" ]] || fail "IPv4 normalization"
[[ "$BACKEND_SCHEME" == "http" ]] || fail "HTTP scheme detection"

normalize_backend "https://emby.example.com:443/" || fail "HTTPS backend rejected"
[[ "$NORMALIZED_BACKEND" == "https://emby.example.com:443" ]] || fail "HTTPS normalization"
[[ "$BACKEND_SCHEME" == "https" ]] || fail "HTTPS scheme detection"

normalize_backend "[2001:db8::1]:8096" || fail "IPv6 backend rejected"
! normalize_backend "999.1.1.1:8096" || fail "invalid IPv4 accepted"
! normalize_backend "127.0.0.1:70000" || fail "invalid port accepted"
! normalize_backend "127.0.0.1:8096/path" || fail "upstream path accepted"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

BACKENDS=("10.0.0.1:8096" "10.0.0.2:8096" "10.0.0.3:8096")
LB_POLICY="first"
SMART_FAILOVER="true"
generated="$tmp_dir/generated.Caddyfile"
: > "$generated"
write_site_block "emby.example.com" "$generated"
grep -Fq "reverse_proxy 10.0.0.1:8096 10.0.0.2:8096 10.0.0.3:8096" "$generated" || fail "backend list missing"
grep -Fq "lb_policy first" "$generated" || fail "primary/failover policy missing"
grep -Fq "health_uri /System/Info/Public" "$generated" || fail "smart health URI missing"
grep -Fq "health_timeout 3s" "$generated" || fail "smart health timeout missing"
grep -Fq "health_fails 2" "$generated" || fail "smart health failure threshold missing"

source_file="$tmp_dir/source.Caddyfile"
remaining_file="$tmp_dir/remaining.Caddyfile"
cat > "$source_file" <<'EOF'
first.example.com {
    reverse_proxy 10.0.0.1:8096 10.0.0.2:8096 {
        lb_policy round_robin
        header_up X-Real-IP {remote_host}
    }
}

second.example.com {
    reverse_proxy 127.0.0.1:8096
}
EOF
remove_site_block "first.example.com" "$source_file" "$remaining_file"
! grep -Fq "first.example.com" "$remaining_file" || fail "target site was not removed"
grep -Fq "second.example.com" "$remaining_file" || fail "unrelated site was removed"

echo "All function tests passed."
