# eyetoolkit/ops-platform

Central ops: **reusable** GitHub Actions workflows + per-site YAML profiles for the entire eyetoolkit.com ecosystem.

## Why one repo?

The user manages ~9 deploy targets (eyetoolkit.com main, blog, clinic, monorepo sub-sites, boardduel, gamezone, mquickcalc…) alone. Without central ops:

- each repo duplicates 200 lines of deploy logic
- 9 SSH keys scattered across 9 secret stores
- 9 different cron fallbacks, 9 different rollback scripts

ops-platform fixes this:

```
┌────────────────────────────────────────────────────────────┐
│  eyetoolkit/ops-platform  (one place)                          │
│  ├─ .github/workflows/deploy-site.yml   ← reusable workflow │
│  ├─ profiles/*.yml                       ← per-site config    │
│  └─ scripts/*.sh                         ← shared bash        │
└────────────────────────────────────────────────────────────┘
       ▲                                                          
       │ workflow_call                                           
       │                                                          
┌────────────────────────────────────────────────────────────┐
│  per-site repo .github/workflows/deploy.yml (12 lines each)    │
│  eyetoolkit/blog.eyetoolkit.com → calls ops-platform          │
│  eyetoolkit/eyetoolkit         → calls ops-platform          │
│  eyetoolkit/eyetoolkit-consensus → calls ops-platform       │
└────────────────────────────────────────────────────────────┘
```

## Layout

```
ops-platform/
├── .github/workflows/
│   └── deploy-site.yml            # reusable workflow (called by others)
├── profiles/                        # one YAML per deployable target
│   ├── eyetoolkit-com.yml          # main site
│   ├── eyetoolkit-blog.yml         # blog
│   ├── eyetoolkit-clinic.yml       # clinic 3 subsystems
│   ├── eyetoolkit-consensus.yml    # consensus
│   ├── eyetoolkit-knowledge.yml    # monorepo sub-site
│   └── ...                          # future sites
├── scripts/
│   ├── deploy-static.sh            # clone → build → backup → rsync → reload
│   ├── deploy-flask.sh             # clone → install → restart systemd
│   ├── health-check.sh             # (future) http probe
│   └── rollback.sh                 # (future) restore last backup
└── README.md
```

## Phase status

| Phase | Status | Notes |
|---|---|---|
| Phase 1 | ✅ done | ops-platform repo + reusable workflow + blog trial |
| Phase 2 | pending | blog deploy.yml switched to workflow_call |
| Phase 3 | pending | 8 more profiles + 8 repo deploy.yml files |
| Phase 4 | pending | rollback + health-check + notify

## How to call from a top-level repo

```yaml
# eyetoolkit/blog.eyetoolkit-com/.github/workflows/deploy.yml
name: Deploy Blog
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  deploy:
    uses: eyetoolkit/ops-platform/.github/workflows/deploy-site.yml@main
    with:
      profile: eyetoolkit-blog
      ref: main
    secrets:
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
      DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
```

> Only **ops-platform** holds `DEPLOY_SSH_KEY` / `DEPLOY_HOST` secrets.
> Per-repo secrets are empty — reusable workflows inherit caller secrets via `workflow_call`.

## Required secrets (in ops-platform)

| Name | Example | Purpose |
|---|---|---|
| `DEPLOY_SSH_KEY` | `-----BEGIN OPENSSH...` | SSH key for `root@101.96.194.237` |
| `DEPLOY_HOST` | `101.96.194.237` | target host (single value shared by all sites today) |
| `DEPLOY_NOTIFY_WEBHOOK` | `https://oapi.dingtalk.com/robot/send?access_token=...` | optional failure alerts |

## Phase 1 trial run (2026-09-30)

- ops-platform repo: https://github.com/eyetoolkit/ops-platform
- trial profile: `profiles/eyetoolkit-blog.yml`
- trial target: blog.eyetoolkit.com (VitePress monorepo sub-site)
- next: switch blog.eyetoolkit.com deploy.yml to workflow_call

## Failure mode

- Step "Build & deploy via SSH" exits non-zero → workflow fails → "Notify failure" tries webhook
- Step "Health check" fails → workflow fails → same notify path
- Manual rollback: SSH into 101.96.194.237, `ls -t /home/blog-deploy/_backup/<site>/ | head -1` → restore that dir