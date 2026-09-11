#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE="$ROOT/fpk/app/bin/sag-service"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/proc/123"/fd "$TMP/proc/124"/fd "$TMP/proc/125"/fd
printf 'next-server (v15.5.20)\0' > "$TMP/proc/123/cmdline"
printf 'unrelated-node\0' > "$TMP/proc/124/cmdline"
printf 'server.js\0' > "$TMP/proc/125/cmdline"

cat > "$TMP/readlink" <<'EOF'
#!/bin/sh
case "$1" in
  */123/cwd) printf '%s\n' '/opt/SAG/web (deleted)' ;;
  */123/exe) printf '%s\n' '/opt/nodejs_v22/bin/node' ;;
  */124/cwd) printf '%s\n' '/opt/other/web' ;;
  */124/exe) printf '%s\n' '/opt/nodejs_v22/bin/node' ;;
  */125/cwd) printf '%s\n' '/opt/SAG/web' ;;
  */125/exe) printf '%s\n' '/opt/python/bin/python3' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/readlink"
PATH="$TMP:$PATH"

awk '
  /^web_process_matches\(\) \{/ { capture=1 }
  capture { print }
  capture && /^\}$/ { exit }
' "$SERVICE" | python3 -c 'import sys; print(sys.stdin.read().replace("/proc/$candidate_pid", "${SYNTH_PROC}/$candidate_pid"), end="")' > "$TMP/function.sh"

# The test uses the same function against a synthetic /proc tree. Production
# keeps the literal /proc path; only this generated test copy is redirected.
# shellcheck disable=SC1091
. "$TMP/function.sh"
APP_ROOT="/opt/SAG"
SYNTH_PROC="$TMP/proc"

[ "$(web_process_matches 123; printf '%s' "$?")" = 0 ]
if web_process_matches 124; then
  printf '%s\n' 'wrong cwd was accepted' >&2
  exit 1
fi
if web_process_matches 125; then
  printf '%s\n' 'wrong executable was accepted' >&2
  exit 1
fi
if web_process_matches abc; then
  printf '%s\n' 'non-numeric pid was accepted' >&2
  exit 1
fi

base_path_value="$(sed -n 's/^BASE_PATH="\([^"]*\)"$/\1/p' "$SERVICE")"
[ "$base_path_value" = "/app/SAG" ] || {
  printf '%s\n' "unexpected BASE_PATH: $base_path_value" >&2
  exit 1
}
web_base_url="http://127.0.0.1:18199${base_path_value}"
root_probe_url="${web_base_url}/"
bootstrap_probe_url="${web_base_url}/api/v1/system/storage-bootstrap"
[ "$root_probe_url" = "http://127.0.0.1:18199/app/SAG/" ]
[ "$bootstrap_probe_url" = "http://127.0.0.1:18199/app/SAG/api/v1/system/storage-bootstrap" ]
case "${bootstrap_probe_url#*://}" in
  *//* )
    printf '%s\n' "bootstrap probe URL contains repeated slashes: $bootstrap_probe_url" >&2
    exit 1
    ;;
esac

printf '%s\n' 'web process matching tests passed'
