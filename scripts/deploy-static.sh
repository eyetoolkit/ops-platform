#!/bin/bash
# Generic static-site deployer for eyetoolkit.com cluster
# Usage: bash deploy-static.sh <profile> <ref> <ops_dir>
#
# Reads profile YAML and:
#   1. Clones the source repo at <ref>
#   2. Runs build_cmd
#   3. Backs up current deploy_dir to _backup/<profile>/<ts>/
#   4. rsync artifact -> remote_dir
#   5. Optionally reloads nginx
#   6. Optional: reports size + diff vs backup
#
# Requires: yq (or python3+PyYAML), git, rsync, ssh-key auth as DEPLOY_USER

set -euo pipefail

PROFILE="$1"        # e.g. eyetoolkit-blog
REF="$2"            # e.g. main
OPS_DIR="$3"        # /opt/ops-platform

PROFILE_FILE="$OPS_DIR/profiles/$PROFILE.yml"
if [ ! -f "$PROFILE_FILE" ]; then
  echo "::error::Profile not found: $PROFILE_FILE"
  exit 1
fi

# parse yaml via python3 (avoid yq install dependency)
eval "$(python3 - <<PYEOF
import yaml, shlex
p = yaml.safe_load(open("$PROFILE_FILE"))
out = []
out.append(f"SITE={shlex.quote(p['site'])}")
out.append(f"DOMAIN={shlex.quote(p['domain'])}")
out.append(f"REPO={shlex.quote(p.get('repo', 'eyetoolkit/' + p['site']))}")
out.append(f"REF_DEFAULT={shlex.quote(p.get('default_ref', 'main'))}")
out.append(f"REPO_DIR={shlex.quote(p['source_repo_dir'])}")
out.append(f"BUILD_CMD={shlex.quote(p['build_cmd'])}")
out.append(f"ARTIFACT={shlex.quote(p['artifact'])}")
out.append(f"REMOTE_DIR={shlex.quote(p['deploy_target']['remote_dir'])}")
out.append(f"NGINX_RELOAD={shlex.quote(str(p['deploy_target'].get('nginx_reload', False)).lower())}")
out.append(f"HEALTH_URL={shlex.quote(p['health_check_url'])}")
print('\n'.join(out))
PYEOF
)"

# 若未显式传 ref，则使用 profile 声明的 default_ref
if [ -z "$REF" ]; then REF="$REF_DEFAULT"; fi
echo "=== Profile: $PROFILE ==="
echo "  site:        $SITE"
echo "  domain:      $DOMAIN"
echo "  repo:        $REPO @ $REF"
echo "  source dir:  $REPO_DIR"
echo "  build cmd:   $BUILD_CMD"
echo "  artifact:    $ARTIFACT"
echo "  remote dir:  $REMOTE_DIR"
echo "  nginx reload:$NGINX_RELOAD"

WORKDIR="/opt/_build_/$PROFILE"
LOG="$WORKDIR/deploy.log"
mkdir -p "$WORKDIR"
echo "=== Deploy log: $LOG ==="
{
    echo
    echo "==== deploy-log: $(date '+%Y-%m-%d %H:%M:%S') profile=$PROFILE ref=$REF ===="
} >> "$LOG"

# Step 1: clone
echo "[1/5] Cloning $REPO @ $REF ..."
# 若已存在 clone 但 remote 与当前 profile 不符（如改了 repo），强制重新 clone
if [ -d "$WORKDIR/repo/.git" ]; then
    EXISTING_REMOTE="$(git -C "$WORKDIR/repo" remote get-url origin 2>/dev/null || true)"
    if [ "$EXISTING_REMOTE" != "https://github.com/$REPO.git" ]; then
        echo "  remote mismatch ($EXISTING_REMOTE), re-cloning"
        rm -rf "$WORKDIR/repo"
    fi
fi
if [ -d "$WORKDIR/repo" ]; then
    cd "$WORKDIR/repo"
    git fetch --depth=1 origin "$REF" 2>&1 | tail -3
    git checkout FETCH_HEAD 2>&1 | tail -3
else
    git clone --depth=1 -b "$REF" "https://github.com/$REPO.git" "$WORKDIR/repo" 2>&1 | tail -3
    cd "$WORKDIR/repo"
fi
echo "  HEAD: $(git rev-parse --short HEAD)"

# Step 2: build
echo "[2/5] Building: $BUILD_CMD"
cd "$WORKDIR/repo"
eval "$BUILD_CMD" 2>&1 | tail -30

ARTIFACT_PATH="$WORKDIR/repo/$ARTIFACT"
if [ ! -d "$ARTIFACT_PATH" ]; then
    echo "::error::Artifact dir missing: $ARTIFACT_PATH"
    exit 1
fi
ARTIFACT_SIZE=$(du -sh "$ARTIFACT_PATH" | awk '{print $1}')
echo "  artifact size: $ARTIFACT_SIZE"

# Step 3: backup current
echo "[3/5] Backing up current $REMOTE_DIR ..."
if [ -d "$REMOTE_DIR" ] && [ "$(ls -A "$REMOTE_DIR" 2>/dev/null)" ]; then
    TS=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="/home/blog-deploy/_backup/$SITE/$TS"
    mkdir -p "$BACKUP_DIR"
    rsync -a --delete "$REMOTE_DIR/" "$BACKUP_DIR/" 2>&1 | tail -3
    echo "  backup → $BACKUP_DIR"
    # keep last 5 backups
    ls -dt /home/blog-deploy/_backup/$SITE/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf
    echo "  kept backups:"
    ls -dt /home/blog-deploy/_backup/$SITE/*/ 2>/dev/null | head -5
else
    echo "  (no current deploy to back up)"
fi

# Step 4: rsync artifact -> remote_dir
echo "[4/5] Deploying: $ARTIFACT_PATH -> $REMOTE_DIR ..."
mkdir -p "$REMOTE_DIR"
rsync -a --delete "$ARTIFACT_PATH/" "$REMOTE_DIR/" 2>&1 | tail -3
chown -R blog-deploy:blog-deploy "$REMOTE_DIR" 2>/dev/null || true
NEW_SIZE=$(du -sh "$REMOTE_DIR" | awk '{print $1}')
echo "  deployed size: $NEW_SIZE"

# Step 5: nginx reload
if [ "$NGINX_RELOAD" = "true" ]; then
    echo "[5/5] nginx -t && nginx -s reload ..."
    nginx -t 2>&1 | tail -3
    nginx -s reload 2>&1 && echo "  reloaded"
else
    echo "[5/5] nginx reload skipped (profile says false)"
fi

echo "=== Done. health: $HEALTH_URL ==="