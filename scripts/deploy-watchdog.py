#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Deploy watchdog -- webhook delivery fallback for the eyetoolkit.com cluster.

WHY
---
GitHub push deliveries occasionally fail at the TCP/TLS connect layer before
ever reaching nginx (GitHub records "502 failed to connect to host" with empty
response headers; nginx access/error logs show no matching request at all).
GitHub does NOT retry a failed push delivery, so one dropped delivery means a
permanently missed deployment. This has happened repeatedly (2026-10-30,
2026-11-06, 2026-11-08) and manual `deploy-static.sh` fixes tend to cover only
one of the six profiles.

The primary path is still /opt/deploy-webhook/receiver.py. This script is a
safety net driven by a systemd timer on the server: it actively reaches OUT to
GitHub and compares the remote branch HEAD against the HEAD actually built in
each profile's build repo (/opt/_build_/<profile>/repo). Only stale profiles
are redeployed.

TRUTH SOURCE
------------
The build repos, NOT a private state file. Both webhook deploys and manual
deploy-static.sh runs update those repos, so a successful webhook deploy makes
the watchdog see IN SYNC and do nothing -- no duplicate deploys, no drift
between two bookkeeping systems.

USAGE
-----
  python3 deploy-watchdog.py                     # normal single pass (timer)
  python3 deploy-watchdog.py --dry-run          # report only, never deploy
  python3 deploy-watchdog.py --repo eyetoolkit/blog   # watch just one repo
  python3 deploy-watchdog.py --skip-inflight-check

Exit code 1 means at least one ls-remote/deploy failed; the next tick retries.
"""
import argparse
import fcntl
import json
import logging
import os
import subprocess
import sys
import time

OPS_DIR = "/opt/ops-platform"
DEPLOY_MAP = "/opt/deploy-webhook/deploy-map.json"
LOCK_PATH = "/opt/deploy-webhook/watchdog.lock"
LOG_PATH = "/var/log/deploy-watchdog.log"
DETAIL_LOG_PATH = "/var/log/deploy-watchdog-detail.log"
# Only repos whose profiles all have a real /opt/_build_/<profile>/repo build
# checkout can be watched: build_head() uses that checkout as the truth source.
# eyetoolkit/clinic and eyetoolkit/clinic-superadmin are Flask apps WITHOUT such
# build repos -- adding them would make build_head() return None every tick,
# i.e. a false STALE and a redeploy every 5 minutes. Keep them out.
DEFAULT_REPOS = [
    "eyetoolkit/blog",
    "eyetoolkit/eyetoolkit",
    "eyetoolkit/eyetoolkit-consensus",
]
REMOTE_TMPL = "https://github.com/%s.git"
BUILD_REPO_TMPL = "/opt/_build_/%s/repo"
LS_REMOTE_TIMEOUT = 60
DEPLOY_TIMEOUT = 1800

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("deploy-watchdog")


def remote_head(repo, branch):
    cmd = ["git", "-c", "credential.helper=store", "ls-remote",
           REMOTE_TMPL % repo, "refs/heads/" + branch]
    r = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=LS_REMOTE_TIMEOUT)
    if r.returncode != 0 or not r.stdout.strip():
        detail = (r.stderr or r.stdout or "").strip()[:200]
        raise RuntimeError("ls-remote failed for %s@%s: %s" % (repo, branch, detail))
    return r.stdout.split()[0]


def build_head(profile):
    path = BUILD_REPO_TMPL % profile
    if not os.path.isdir(os.path.join(path, ".git")):
        return None
    r = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                       capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def deploy_in_flight():
    """Do not overlap a webhook-driven deploy (and its nginx reloads).

    The character class / alternation avoids pgrep matching its own command
    line; the watchdog's own cmdline contains watchdog.py, not deploy-*.sh.
    """
    r = subprocess.run(["pgrep", "-f", r"deploy-(static|flask)\.sh"],
                       capture_output=True, text=True)
    return r.returncode == 0


def deploy(profile, script, branch, dry_run):
    script_path = os.path.join(OPS_DIR, "scripts", "deploy-%s.sh" % script)
    if dry_run:
        log.info("DRY-RUN would deploy profile=%s script=%s ref=%s",
                 profile, script, branch)
        return True
    if not os.path.exists(script_path):
        log.error("DEPLOY SKIP missing script %s", script_path)
        return False
    log.info("DEPLOY START profile=%s script=%s ref=%s", profile, script, branch)
    t0 = time.time()
    try:
        with open(DETAIL_LOG_PATH, "a") as out:
            out.write("\n=== %s watchdog deploy %s @ %s ===\n" % (
                time.strftime("%Y-%m-%d %H:%M:%S"), profile, branch))
            out.flush()
            proc = subprocess.run(
                ["bash", script_path, profile, branch, OPS_DIR],
                stdout=out, stderr=subprocess.STDOUT, timeout=DEPLOY_TIMEOUT,
            )
        rc = proc.returncode
    except Exception as e:  # noqa: BLE001
        log.exception("DEPLOY EXC profile=%s: %s", profile, e)
        return False
    dt = int(time.time() - t0)
    if rc == 0:
        log.info("DEPLOY OK profile=%s in %ds", profile, dt)
        return True
    log.error("DEPLOY FAIL profile=%s rc=%s in %ds (will retry next tick)",
              profile, rc, dt)
    return False


def acquire_lock():
    """Non-blocking exclusive lock so timer ticks never overlap."""
    fp = open(LOCK_PATH, "a+")
    try:
        fcntl.flock(fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fp.close()
        return None
    return fp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="report drift but do not deploy")
    ap.add_argument("--repo", action="append", dest="repos",
                    help="override watched repo (repeatable)")
    ap.add_argument("--skip-inflight-check", action="store_true",
                    help="ignore an in-flight deploy (for controlled tests)")
    args = ap.parse_args()

    lock = acquire_lock()
    if lock is None:
        log.info("SKIP another watchdog pass is still running")
        return 0

    if not args.skip_inflight_check and deploy_in_flight():
        log.info("SKIP deploy-static.sh / deploy-flask.sh in flight; next tick will retry")
        return 0

    with open(DEPLOY_MAP) as f:
        deploy_map = json.load(f)

    repos = args.repos or DEFAULT_REPOS
    failed = False
    for repo in repos:
        entry = deploy_map.get(repo)
        if not entry:
            log.warning("IGNORE unmapped repo=%s", repo)
            continue
        branch = entry["expected_branch"]
        try:
            head = remote_head(repo, branch)
        except Exception as e:  # noqa: BLE001
            log.warning("LS-REMOTE FAIL repo=%s: %s (skip this tick)", repo, e)
            failed = True
            continue
        log.info("CHECK repo=%s@%s remote=%s profiles=%d",
                 repo, branch, head[:12], len(entry["profiles"]))

        stale = []
        for pf in entry["profiles"]:
            name = pf["name"]
            built = build_head(name)
            if built == head:
                log.info("  IN SYNC  profile=%s head=%s", name, (built or "-")[:12])
            else:
                log.info("  STALE    profile=%s built=%s want=%s",
                         name, (built or "missing")[:12], head[:12])
                stale.append(pf)

        if not stale:
            log.info("REPO IN SYNC repo=%s", repo)
            continue

        log.info("MISS repo=%s stale_profiles=%d -> deploy stale profiles",
                 repo, len(stale))
        for pf in stale:
            if not deploy(pf["name"], pf.get("script", "static"), branch, args.dry_run):
                failed = True
        if not args.dry_run:
            log.info("WATCHDOG DONE repo=%s attempted=%d", repo, len(stale))

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
