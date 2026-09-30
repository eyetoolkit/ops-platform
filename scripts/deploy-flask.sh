#!/bin/bash
# Generic Flask app deployer (not used in Phase 1, reserved for clinic/boardduel etc.)
# Usage: bash deploy-flask.sh <profile> <ref> <ops_dir>
set -euo pipefail
PROFILE="$1"; REF="$2"; OPS_DIR="$3"
PROFILE_FILE="$OPS_DIR/profiles/$PROFILE.yml"
[ -f "$PROFILE_FILE" ] || { echo "profile missing"; exit 1; }

eval "$(python3 - "$PROFILE_FILE" <<'PYEOF'
import yaml, shlex, sys
p = yaml.safe_load(open(sys.argv[1]))
out = []
for k, v in [
    ('SITE', p['site']),
    ('REPO', p.get('repo', f"eyetoolkit/{p['site']}")),
    ('REPO_DIR', p['source_repo_dir']),
    ('REMOTE_DIR', p['deploy_target']['remote_dir']),
    ('BUILD_CMD', p.get('build_cmd', 'pip install -r requirements.txt')),
    ('SYSTEMD_UNIT', p['deploy_target']['systemd_unit']),
]:
    out.append(f"{k}={shlex.quote(v)}")
print('\n'.join(out))
PYEOF
)"

echo "=== Deploy Flask: $SITE @ $REF ==="
WORKDIR="/opt/_build_/$PROFILE"
mkdir -p "$WORKDIR"
LOG="$WORKDIR/deploy.log"

cd /opt
if [ -d "$SITE" ]; then
    cd "$SITE"
    git fetch --depth=1 origin "$REF"
    git checkout FETCH_HEAD
fi
cd "$WORKDIR/repo" 2>/dev/null || { git clone --depth=1 -b "$REF" "https://github.com/$REPO.git" "$WORKDIR/repo"; cd "$WORKDIR/repo"; }

eval "$BUILD_CMD" 2>&1 | tail -10

systemctl restart "$SYSTEMD_UNIT"
sleep 2
systemctl status "$SYSTEMD_UNIT" --no-pager -n 3 | head -10
echo "=== Done. $SITE deployed ==="