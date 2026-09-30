#!/bin/bash
# Generic Flask app deployer: live-dir git sync + optional build_cmd + systemd restart.
# Usage: bash deploy-flask.sh <profile> <ref> <ops_dir>
set -euo pipefail
PROFILE="$1"; REF="$2"; OPS_DIR="$3"
PROFILE_FILE="$OPS_DIR/profiles/$PROFILE.yml"
[ -f "$PROFILE_FILE" ] || { echo "profile missing: $PROFILE_FILE"; exit 1; }

eval "$(python3 - "$PROFILE_FILE" <<'PYEOF'
import yaml, shlex, sys
p = yaml.safe_load(open(sys.argv[1]))
out = []
for k, v in [
    ('SITE', p['site']),
    ('REPO', p['repo']),
    ('REF_DEFAULT', p.get('default_ref', 'main')),
    ('LIVE_DIR', p['deploy_target']['remote_dir']),
    ('BUILD_CMD', p.get('build_cmd', '')),
    ('UNITS', ' '.join(p['deploy_target'].get('systemd_unit', []))),
]:
    out.append(f"{k}={shlex.quote(v)}")
print('\n'.join(out))
PYEOF
)"

# REF 回退：空 -> profile 的 default_ref（铁律：链路上不得有 main 兜底）
if [ -z "$REF" ]; then REF="$REF_DEFAULT"; fi

echo "=== Deploy Flask: $SITE @ $REF ==="
echo "  live dir: $LIVE_DIR"
echo "  units:    $UNITS"
WORKDIR="/opt/_build_/$PROFILE"
mkdir -p "$WORKDIR"
LOG="$WORKDIR/deploy.log"
{
echo ""
echo "==== deploy-log: $(date '+%Y-%m-%d %H:%M:%S') profile=$PROFILE ref=$REF ===="

# 1) 同步 live 目录（live 目录本身就是 git 工作副本）
if [ -d "$LIVE_DIR/.git" ]; then
  EXISTING_REMOTE="$(git -C "$LIVE_DIR" remote get-url origin 2>/dev/null || true)"
  if [ "$EXISTING_REMOTE" != "https://github.com/$REPO.git" ]; then
    echo "  remote mismatch ($EXISTING_REMOTE), re-cloning"
    rm -rf "$LIVE_DIR"
  fi
fi
if [ -d "$LIVE_DIR/.git" ]; then
  git -C "$LIVE_DIR" fetch --depth=1 origin "$REF" 2>&1 | tail -2
  git -C "$LIVE_DIR" checkout -f FETCH_HEAD 2>&1 | tail -2
else
  git clone --depth=1 -b "$REF" "https://github.com/$REPO.git" "$LIVE_DIR" 2>&1 | tail -3
fi

cd "$LIVE_DIR"
echo "  HEAD: $(git log --oneline -1)"

# 2) 可选构建步骤（依赖安装等）
if [ -n "$BUILD_CMD" ]; then
  echo "  build: $BUILD_CMD"
  eval "$BUILD_CMD" 2>&1 | tail -5
fi

# 3) 重启 systemd 单元并验证 active
for u in $UNITS; do
  systemctl restart "$u"
  sleep 2
  STATE="$(systemctl is-active "$u")"
  echo "  $u -> $STATE"
  if [ "$STATE" != "active" ]; then
    journalctl -u "$u" --no-pager -n 10 | tail -5
    echo "  !! $u failed to start"
    exit 1
  fi
done

echo "=== Done. $SITE deployed ==="
} 2>&1 | tee -a "$LOG"
