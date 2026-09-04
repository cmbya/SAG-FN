#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

env_value() {
  name="$1"
  fallback="$2"
  value="$(printenv "$name" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    value="$fallback"
  fi
  printf '%s' "$value"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

UPSTREAM_REPO="$(env_value UPSTREAM_REPO 'Zleap-AI/SAG')"
UPSTREAM_TAG="$(env_value UPSTREAM_TAG '')"
LOCAL_VERSION="$(env_value LOCAL_VERSION '0.1.0')"
OUT_DIR="$(env_value OUT_DIR "$ROOT/dist")"
SOURCE_DIR="$(env_value SAG_SOURCE_DIR '')"
SKIP_PATCH="$(env_value SAG_SKIP_PATCH '0')"
SKIP_BUILD="$(env_value SAG_SKIP_BUILD '0')"
RUNNER_TEMP_DIR="$(env_value RUNNER_TEMP "$ROOT/.tmp")"
GLIBC_MAX="$(env_value GLIBC_MAX '2.35')"
LANCEDB_COMPAT_VERSION="$(env_value LANCEDB_COMPAT_VERSION '0.38.0')"
SAG_CPU_SMOKE="$(env_value SAG_CPU_SMOKE '0')"
SAG_QEMU_CPU="$(env_value SAG_QEMU_CPU 'Nehalem')"
BUILDER_COMMIT="$(env_value BUILDER_COMMIT '')"

[ -n "$UPSTREAM_TAG" ] || die "UPSTREAM_TAG is required"
[[ "$LOCAL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid LOCAL_VERSION: $LOCAL_VERSION"
[[ "$UPSTREAM_TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "UPSTREAM_TAG must be the upstream SAG stable tag (for example v1.8.6), not the local package version: $UPSTREAM_TAG"
[ "$UPSTREAM_TAG" != "$LOCAL_VERSION" ] || die "UPSTREAM_TAG is the upstream SAG tag (for example v1.8.6); $UPSTREAM_TAG is the local package version"
[[ "$GLIBC_MAX" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid GLIBC_MAX: $GLIBC_MAX"
[[ "$LANCEDB_COMPAT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid LANCEDB_COMPAT_VERSION: $LANCEDB_COMPAT_VERSION"
case "$SAG_CPU_SMOKE" in
  0|1) ;;
  *) die "SAG_CPU_SMOKE must be 0 or 1" ;;
esac

UPSTREAM_VERSION="$(printf '%s' "$UPSTREAM_TAG" | sed 's/^v//')"
ASSET_NAME="$(printf 'SAG_%s_%s_fnOS_x86.fpk' "$UPSTREAM_VERSION" "$LOCAL_VERSION")"
if [ -z "$BUILDER_COMMIT" ]; then
  BUILDER_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
fi

for command_name in git npm node uv python3 tar md5sum sha256sum gzip sed awk convert file objdump grep sort; do
  require_command "$command_name"
done

mkdir -p "$OUT_DIR" "$RUNNER_TEMP_DIR"
if [ -z "$SOURCE_DIR" ]; then
  WORK_DIR="$(mktemp -d "$RUNNER_TEMP_DIR/sag-fpk.XXXXXX")"
  REMOVE_WORK_DIR=1
  SOURCE_DIR="$WORK_DIR/source"
  git clone --filter=blob:none --depth 1 --branch "$UPSTREAM_TAG" --single-branch \
    "https://github.com/$UPSTREAM_REPO.git" "$SOURCE_DIR"
else
  SOURCE_DIR="$(CDPATH= cd -- "$SOURCE_DIR" && pwd)"
  WORK_DIR="$(mktemp -d "$RUNNER_TEMP_DIR/sag-fpk.XXXXXX")"
  REMOVE_WORK_DIR=1
fi

cleanup() {
  if [ "$REMOVE_WORK_DIR" = "1" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

if [ "$SKIP_PATCH" != "1" ]; then
  git -C "$SOURCE_DIR" apply "$ROOT/patches/sag-fnos.patch"
fi

if [ "$SKIP_BUILD" != "1" ]; then
  (
    cd "$SOURCE_DIR/apps/web"
    npm ci --no-audit --no-fund
    NEXT_PUBLIC_API_BASE="/app/SAG" \
      SAG_BASE_PATH="/app/SAG" \
      SAG_INTERNAL_API_URL="http://127.0.0.1:18089" \
      npm run build
  )
  (
    cd "$SOURCE_DIR/apps/api"
    uv sync --frozen --extra desktop
  )
  API_PYTHON="$SOURCE_DIR/apps/api/.venv/bin/python"
  [ -x "$API_PYTHON" ] || die "uv did not create the API virtualenv"
  uv pip uninstall --python "$API_PYTHON" lancedb
  uv pip install --python "$API_PYTHON" --no-deps "lancedb-compat==$LANCEDB_COMPAT_VERSION"

  # lancedb-compat ships the lancedb namespace but its entry point still
  # asks importlib.metadata for the historical distribution name. Add a
  # local metadata alias so both the Python import and PyInstaller work.
  "$API_PYTHON" - "$LANCEDB_COMPAT_VERSION" <<'PY'
from importlib import metadata
from pathlib import Path
import shutil
import sys
import sysconfig

expected = sys.argv[1]
site = Path(sysconfig.get_paths()["purelib"])
compat_dist = next(site.glob("lancedb_compat-*.dist-info"), None)
if compat_dist is None:
    raise SystemExit("lancedb-compat dist-info directory is missing")
compat_version = metadata.version("lancedb-compat")
if compat_version != expected:
    raise SystemExit(f"lancedb-compat version mismatch: {compat_version} != {expected}")
alias_dist = site / f"lancedb-{compat_version}.dist-info"
if not alias_dist.exists():
    shutil.copytree(compat_dist, alias_dist)
metadata_file = alias_dist / "METADATA"
metadata_text = metadata_file.read_text(encoding="utf-8")
if "Name: lancedb-compat\n" not in metadata_text:
    raise SystemExit("unexpected lancedb-compat metadata format")
metadata_file.write_text(
    metadata_text.replace("Name: lancedb-compat\n", "Name: lancedb\n", 1),
    encoding="utf-8",
)
record_file = alias_dist / "RECORD"
if record_file.exists():
    record_file.unlink()
print(f"Created lancedb metadata alias: {alias_dist.name}")
PY

  SMOKE_SCRIPT="$WORK_DIR/lancedb-smoke.py"
  cat > "$SMOKE_SCRIPT" <<'PY'
import os
import tempfile
from importlib.metadata import version

import lancedb

expected = os.environ["LANCEDB_COMPAT_EXPECTED"]
assert version("lancedb-compat") == expected
with tempfile.TemporaryDirectory(prefix="sag-lancedb-smoke-") as directory:
    database = lancedb.connect(directory)
    table = database.create_table(
        "smoke",
        data=[{"vector": [0.0, 1.0], "text": "ok"}],
    )
    rows = table.search([0.0, 1.0]).limit(1).to_list()
    assert rows and rows[0]["text"] == "ok"
print(f"LanceDB compatibility smoke passed: {expected}")
PY

  LANCEDB_COMPAT_EXPECTED="$LANCEDB_COMPAT_VERSION" "$API_PYTHON" "$SMOKE_SCRIPT"
  if [ "$SAG_CPU_SMOKE" = "1" ]; then
    QEMU_BIN="$(command -v qemu-x86_64 || command -v qemu-x86_64-static || true)"
    [ -n "$QEMU_BIN" ] || die "SAG_CPU_SMOKE=1 requires qemu-x86_64 or qemu-x86_64-static"
    LANCEDB_COMPAT_EXPECTED="$LANCEDB_COMPAT_VERSION" QEMU_LD_PREFIX=/ \
      "$QEMU_BIN" -cpu "$SAG_QEMU_CPU" "$API_PYTHON" "$SMOKE_SCRIPT"
  fi

  (
    cd "$SOURCE_DIR/apps/api"
    "$API_PYTHON" -m PyInstaller --clean --noconfirm \
      --distpath "$SOURCE_DIR/apps/api/dist/desktop" \
      --workpath "$WORK_DIR/pyinstaller" \
      packaging/sag-api.spec
  )
fi

check_glibc_compatibility() {
  local root="$1"
  local max_allowed="$2"
  local elf_path
  local description
  local required_version
  local highest_required
  local failed=0

  printf 'Checking backend ELF glibc requirements (maximum GLIBC_%s)\n' "$max_allowed"
  while IFS= read -r -d '' elf_path; do
    description="$(file -b "$elf_path" 2>/dev/null || true)"
    [[ "$description" == *ELF* ]] || continue
    highest_required="$({
      objdump -T "$elf_path" 2>/dev/null \
        | grep -oE '\(GLIBC_[0-9]+(\.[0-9]+)+\)' \
        | tr -d '()' \
        | sed 's/^GLIBC_//' \
        | sort -Vu \
        | tail -n 1
    } || true)"
    [ -n "$highest_required" ] || continue
    required_version="$highest_required"
    if [ "$(printf '%s\n%s\n' "$max_allowed" "$required_version" | sort -V | tail -n 1)" != "$max_allowed" ]; then
      printf 'ERROR: %s requires GLIBC_%s; build target allows up to GLIBC_%s\n' \
        "$elf_path" "$required_version" "$max_allowed" >&2
      failed=1
    fi
  done < <(find "$root" -type f -print0)

  [ "$failed" -eq 0 ] || die "backend is not compatible with the selected fnOS glibc target"
}

FRONTEND_STANDALONE="$SOURCE_DIR/apps/web/.next/standalone"
FRONTEND_STATIC="$SOURCE_DIR/apps/web/.next/static"
FRONTEND_PUBLIC="$SOURCE_DIR/apps/web/public"
BACKEND_DIST="$SOURCE_DIR/apps/api/dist/desktop/sag-api"
ICON_SOURCE="$FRONTEND_PUBLIC/sag-icon.png"

[ -f "$FRONTEND_STANDALONE/server.js" ] || die "Next standalone output is missing"
[ -d "$FRONTEND_STATIC" ] || die "Next static output is missing"
[ -d "$BACKEND_DIST" ] || die "PyInstaller output is missing"
[ -f "$BACKEND_DIST/sag-api" ] || die "PyInstaller executable is missing"
[ -f "$ICON_SOURCE" ] || die "SAG icon is missing"
[ -f "$SOURCE_DIR/LICENSE" ] || die "upstream LICENSE is missing"
check_glibc_compatibility "$BACKEND_DIST" "$GLIBC_MAX"

PACKAGE_DIR="$WORK_DIR/package"
APP_DIR="$PACKAGE_DIR/app"
mkdir -p "$APP_DIR/web" "$APP_DIR/backend/sag-api" "$APP_DIR/ui/images"

cp -a "$ROOT/fpk/app/." "$APP_DIR/"
cp -a "$FRONTEND_STANDALONE/." "$APP_DIR/web/"
mkdir -p "$APP_DIR/web/.next/static" "$APP_DIR/web/public"
cp -a "$FRONTEND_STATIC/." "$APP_DIR/web/.next/static/"
cp -a "$FRONTEND_PUBLIC/." "$APP_DIR/web/public/"
cp -a "$BACKEND_DIST/." "$APP_DIR/backend/sag-api/"

convert "$ICON_SOURCE" -resize 64x64 "$APP_DIR/ui/images/icon_64.png"
convert "$ICON_SOURCE" -resize 256x256 "$APP_DIR/ui/images/icon_256.png"
convert "$ICON_SOURCE" -resize 256x256 "$PACKAGE_DIR/ICON_256.PNG"
convert "$ICON_SOURCE" -resize 64x64 "$PACKAGE_DIR/ICON.PNG"

cp -a "$ROOT/fpk/cmd" "$PACKAGE_DIR/cmd"
cp -a "$ROOT/fpk/config" "$PACKAGE_DIR/config"
cp -a "$ROOT/fpk/wizard" "$PACKAGE_DIR/wizard"
cp "$SOURCE_DIR/LICENSE" "$PACKAGE_DIR/LICENSE-SAG.txt"

sed "s/__LOCAL_VERSION__/$LOCAL_VERSION/g" "$ROOT/fpk/manifest.template" > "$PACKAGE_DIR/manifest"

tar -czf "$PACKAGE_DIR/app.tgz.tmp" \
  --sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner \
  -C "$APP_DIR" .
mv -f "$PACKAGE_DIR/app.tgz.tmp" "$PACKAGE_DIR/app.tgz"

APP_TGZ_MD5="$(md5sum "$PACKAGE_DIR/app.tgz" | awk '{print $1}')"
sed -i "s/__APP_TGZ_MD5__/$APP_TGZ_MD5/g" "$PACKAGE_DIR/manifest"

grep -q '^version=[0-9]\+\.[0-9]\+\.[0-9]\+$' "$PACKAGE_DIR/manifest" \
  || die "manifest version is not pure X.Y.Z"
grep -q "^checksum=$APP_TGZ_MD5$" "$PACKAGE_DIR/manifest" \
  || die "manifest checksum does not match app.tgz"
gzip -t "$PACKAGE_DIR/app.tgz"
tar -tzf "$PACKAGE_DIR/app.tgz" >/dev/null
sh -n "$PACKAGE_DIR/cmd/main"
sh -n "$APP_DIR/bin/sag-service"
node --check "$APP_DIR/bin/sag-gateway.mjs"

FPK_TEMP="$OUT_DIR/$ASSET_NAME.tmp"
tar -czf "$FPK_TEMP" \
  --sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner \
  -C "$PACKAGE_DIR" \
  ICON.PNG ICON_256.PNG LICENSE-SAG.txt app.tgz cmd config manifest wizard
mv -f "$FPK_TEMP" "$OUT_DIR/$ASSET_NAME"
gzip -t "$OUT_DIR/$ASSET_NAME"
tar -tzf "$OUT_DIR/$ASSET_NAME" >/dev/null

UPSTREAM_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
LANCEDB_DISTRIBUTION="lancedb-compat"
export ASSET_NAME LOCAL_VERSION UPSTREAM_REPO UPSTREAM_TAG UPSTREAM_VERSION UPSTREAM_COMMIT BUILDER_COMMIT LANCEDB_COMPAT_VERSION LANCEDB_DISTRIBUTION
python3 - "$OUT_DIR/build-info.json" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

output = {
    "app": "SAG",
    "architecture": "x86_64",
    "asset_name": os.environ["ASSET_NAME"],
    "local_version": os.environ["LOCAL_VERSION"],
    "upstream_repo": os.environ["UPSTREAM_REPO"],
    "upstream_tag": os.environ["UPSTREAM_TAG"],
    "upstream_version": os.environ["UPSTREAM_VERSION"],
    "upstream_commit": os.environ["UPSTREAM_COMMIT"],
    "builder_commit": os.environ["BUILDER_COMMIT"],
    "lancedb_distribution": os.environ["LANCEDB_DISTRIBUTION"],
    "lancedb_version": os.environ["LANCEDB_COMPAT_VERSION"],
    "cpu_baseline": "x86-64-v2",
    "built_at": datetime.now(timezone.utc).isoformat(),
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(output, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY

cat > "$OUT_DIR/README.md" <<EOF
# SAG fnOS x86 FPK

- 本地包版本：$LOCAL_VERSION
- 上游 SAG 版本：$UPSTREAM_TAG
- 上游提交：$UPSTREAM_COMMIT
- 打包源码提交：$BUILDER_COMMIT
- LanceDB：$LANCEDB_DISTRIBUTION==$LANCEDB_COMPAT_VERSION（x86-64-v2）
- 架构：x86_64
- FPK 文件：$ASSET_NAME
- 默认 WebUI 端口：18088
- 依赖：fnOS nodejs_v22

本包使用 Next.js standalone 前端和 PyInstaller 原生后端，不需要 Docker。
后端只监听本机回环地址，前端通过 fnOS Unix socket 网关访问。
配置、SQLite、LanceDB、上传文件和日志保存在应用持久化数据目录，升级时保留。
EOF

(cd "$OUT_DIR" && sha256sum "$ASSET_NAME" > SHA256SUMS)
printf 'Built %s\n' "$OUT_DIR/$ASSET_NAME"
