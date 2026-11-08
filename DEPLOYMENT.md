# eyetoolkit 全站部署链路（Runbook）

> 版本：2026-10-29 定稿 ｜ 维护：改此文件后 push 本仓即生效（文档随基础设施版本化）
> 本文档是部署链路的**唯一真相源**，与服务器实际配置保持同步。

## 一、架构总览

```
开发端（本地 Windows 工作区）            部署端（火山服务器 101.96.194.237）
┌─────────────────────────┐            ┌──────────────────────────────────────┐
│ eyetoolkit/             │  git push  │ nginx /webhook → 127.0.0.1:9090      │
│ blog/                   │ ──────────→│ deploy-webhook.service (HMAC-SHA256) │
│ ops-platform/           │   GitHub   │   ↓ deploy-map.json（仓+分支匹配）    │
│ eyetoolkit-consensus/   │            │   ↓ 单线程队列 + 去重防抖             │
│ clinic/                 │            │ deploy-static.sh / deploy-flask.sh   │
└─────────────────────────┘            │   ↓ 浅拉仓→构建→备份→rsync→reload    │
                                       │ /home/blog-deploy/<site>（webroot）  │
                                       └──────────────────────────────────────┘
```

**铁律：服务器上不执行任何开发。** 代码只改本地 → push → 自动部署。
（2026-10-29 起开发端全部迁回本地，服务器 /opt 下开发副本已删除。）

## 二、仓库 × 分支 × Profile 映射（deploy-map.json）

| GitHub 仓 | 触发分支 | Profile | 类型 | 线上位置 | artifact |
|---|---|---|---|---|---|
| eyetoolkit/eyetoolkit | restore/chinese-v1 | eyetoolkit-main | static(Next.js) | eyetoolkit.com | out/ |
| eyetoolkit/eyetoolkit-consensus | main | eyetoolkit-consensus | static(VitePress) | eyetoolkit.com/consensus/ | docs/.vitepress/dist |
| eyetoolkit/blog | master | eyetoolkit-blog | static(VitePress) | blog.eyetoolkit.com | sites/blog/docs/.vitepress/dist |
| eyetoolkit/blog | master | eyetoolkit-wiki | static(VitePress) | eyetoolkit.com/wiki/ | sites/wiki/docs/.vitepress/dist |
| eyetoolkit/blog | master | eyetoolkit-drugs | static(VitePress) | eyetoolkit.com/drugs/ | sites/drugs/…/dist |
| eyetoolkit/blog | master | eyetoolkit-exam | static(VitePress) | eyetoolkit.com/exam/ | sites/exam/…/dist |
| eyetoolkit/blog | master | eyetoolkit-knowledge | static(VitePress) | eyetoolkit.com/knowledge/ | sites/knowledge/…/dist |
| eyetoolkit/blog | master | eyetoolkit-life | static(VitePress) | eyetoolkit.com/life/ | sites/life/…/dist |
| eyetoolkit/clinic | main | eyetoolkit-clinic | flask | clinic.eyetoolkit.com | — |
| eyetoolkit/clinic-superadmin | main | eyetoolkit-clinic-superadmin | flask | — | — |

⚠️ 推错分支（如 blog 的 production 分支）只会被 IGNORE，不会部署。blog 一次 push 触发 6 个 profile 串行部署。

## 三、部署管线细节（deploy-static.sh 五步）

1. **浅拉仓**：`/opt/_build_/<profile>/repo`（独立构建仓，缓存 node_modules 加速）
   ⚠️ 仓内残留未跟踪文件会挡 `git checkout FETCH_HEAD`（drugs 曾因 package-lock.json 连挂）→ 删掉重跑。
2. **构建**：按 profile 的 build_cmd；失败自动清 node_modules 重试一次（应对 ETXTBSY/ENOTEMPTY 竞态）。
   ⚠️ 所有 `npm ci` 必须带 `--foreground-scripts`（ETXTBSY 根治方案，fbbf5a6 固化）。
3. **备份**：rsync 当前 webroot → `/home/blog-deploy/_backup/<site>/<时间戳>/`，留 5 份。
4. **上线**：`rsync -a --delete artifact → webroot`，chown blog-deploy。
5. **reload**：`nginx -t && nginx -s reload`。

主站特例：build_cmd 含 `rm -rf out/tools/color-vision`（color-vision 安全门，永不上线）。

## 四、监控与日志

| 日志 | 内容 |
|---|---|
| `/var/log/deploy-webhook.log` | PUSH/IGNORE/START/OK/FAIL 汇总 |
| `/opt/_build_/<profile>/webhook-deploy.log` | 单次部署完整输出（排障看这个） |
| 企业微信通知 | 每次 OK/FAIL 推送（receiver 的 NOTIFY_URL） |
| `/var/log/deploy-watchdog.log` | 兜底轮询：CHECK / IN SYNC / STALE / MISS / DEPLOY OK\|FAIL |
| `/var/log/deploy-watchdog-detail.log` | watchdog 触发的单次部署完整输出 |

健康自检：9 个入口全 200（主站/consensus/wiki/drugs/exam/knowledge/life/blog/clinic）。

### 4.1 兜底轮询 deploy-watchdog（2026-11-08 新增）

**背景**：GitHub 的 push delivery 偶发在 TCP/TLS 建连层失败（GitHub 侧记录 `502 failed to connect to host`、响应头为空；nginx 无任何对应请求日志），且 **GitHub 不重发失败的 push delivery** → 一次丢包即永久漏部署。改 `receiver.py` 的队列逻辑修不到这个环节（它只负责「收到之后」）。

**机制**：systemd timer 每 5 分钟调用 `scripts/deploy-watchdog.py`：

1. 服务器侧主动 `git ls-remote` 取各仓部署分支的 HEAD（默认 3 个仓：`eyetoolkit/blog@master`、`eyetoolkit/eyetoolkit@restore/chinese-v1`、`eyetoolkit/eyetoolkit-consensus@main`）；
2. 逐个比对 `/opt/_build_/<profile>/repo` 的实际构建 HEAD（**真相源**：webhook 部署与手动部署都会更新它，所以 webhook 成功时 watchdog 看到 IN SYNC 不会重复部署，也无需另建 state 文件）；
3. 只对 STALE 的 profile 补跑 `deploy-static.sh`；失败不写任何状态，下一轮自动重试；
4. `flock` 防 tick 重叠；检测到 `deploy-*.sh` 正在跑就 SKIP，避免与 webhook 部署及 nginx reload 撞车。

**文件**：`scripts/deploy-watchdog.py`、`systemd/deploy-watchdog.{service,timer}`（模板，装到 `/etc/systemd/system/`）。

```bash
systemctl status deploy-watchdog.timer
python3 /opt/ops-platform/scripts/deploy-watchdog.py --dry-run   # 只看漂移不部署
journalctl -u deploy-watchdog.service -n 50
```

扩展监控其它仓：`--repo <owner/repo>`（可重复），或改脚本 `DEFAULT_REPOS`（2026-11-08 19:50 起覆盖 3 仓 8 个 profile，主站与 consensus 也纳入兜底）。

🔴 **不要加 `eyetoolkit/clinic` / `eyetoolkit/clinic-superadmin`**：这两个是 Flask 应用，`/opt/_build_/<profile>/repo` 不存在，`build_head()` 恒返回 `None` → 每轮都误判 STALE → 每 5 分钟重复部署一次。只有「所有 profile 都有真实构建仓 checkout」的仓才能进 `DEFAULT_REPOS`；clinic 类仓需要另做基于「已部署 commit 记录」的判据。

**服务器安装/更新**：
```bash
git -C /opt/ops-platform pull --ff-only origin main
cp /opt/ops-platform/systemd/deploy-watchdog.service /etc/systemd/system/
cp /opt/ops-platform/systemd/deploy-watchdog.timer  /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now deploy-watchdog.timer
systemctl start deploy-watchdog.service   # 立即验证一次，正常应 exit 0
```

🔴 **单元必须显式 `Environment=HOME=/root`**（2026-11-08 踩坑）：systemd 服务不继承 HOME，`git credential-store` 找不到 `/root/.git-credentials`，`ls-remote` 报 `fatal: unable to set up default path; use --file` / `could not read Username`，服务 exit=1；而在 SSH 里手动跑脚本完全正常 —— 极易误判成脚本 bug。

## 五、排障手册（按症状）

| 症状 | 原因 → 处置 |
|---|---|
| FAIL rc=1 in 3~4s | 构建仓被未跟踪文件挡 checkout → 删除残留（如 package-lock.json）重跑 |
| FAIL 带 ETXTBSY/ENOTEMPTY | npm 竞态 → 脚本已自动重试；仍败则 `rm -rf /opt/_build_/<profile>/repo/sites/*/node_modules` 重跑 |
| `vitepress: not found` / ESM export 报错 | node_modules 损坏 → 同上清理重跑 |
| 部署成功但线上没变化 | 推的分支不在映射表（IGNORE）；或改的是本地没 push；或看错了线上页（首页导航是 page.tsx 内联，SiteNav 只在子页面） |
| webhook 日志**连 `PUSH` 行都没有**、线上没变 | GitHub→源站建连层丢投递（GitHub 侧 502 `failed to connect to host`，nginx 无对应请求），**GitHub 不重发** → watchdog 5 分钟内自动补；急用手动跑 `python3 /opt/ops-platform/scripts/deploy-watchdog.py`。GitHub 侧证据用 `GET /repos/eyetoolkit/blog/hooks/{id}/deliveries` 查 |
| FAIL 带断言/artifact 缺失 | 看 webhook-deploy.log 的 `::error::` 行定位 |

手动兜底部署（webhook 失效时）：
```bash
ssh root@101.96.194.237   # 密钥 ~/.ssh/game_ed25519
# 推荐：一次补齐所有 stale profile（手动单跑 deploy-static.sh 极易只补一个、漏掉其余 5 个）
python3 /opt/ops-platform/scripts/deploy-watchdog.py
python3 /opt/ops-platform/scripts/deploy-watchdog.py --dry-run   # 先只查看差异
# 或明确只补单个 profile
bash /opt/ops-platform/scripts/deploy-static.sh <profile名> <分支> /opt/ops-platform
```

回滚：从 `/home/blog-deploy/_backup/<site>/<旧时间戳>/` rsync 回 webroot。

## 六、红线（历史事故换来的）

1. **任何机器上的本地修改必须 commit + push**——服务器侧任何 git checkout 类操作都会抹掉未推送工作。
   （2026-10-29：Actions 的 `git checkout -f` 静默回滚了 /opt/ops-platform 未提交修复。）
2. **双管线禁止**：GitHub Actions deploy.yml 已去掉 push 触发（仅 workflow_dispatch 手动兜底），
   自动部署只走服务器 webhook——两管线并发会争抢同一构建仓（同日事故）。
3. 旧 VitePress 断言（`assets/style.*.css`）**不要恢复**：对 Next.js 产物必挂（同日事故直接死因）。
4. 线上文章页判据、封面解析链等站点内容规则见工作区 MEMORY.md，此处只管部署。
5. **GitHub push delivery 失败不重发**（2026-11-08 定位）：判据是「`/var/log/deploy-webhook.log` 连 `PUSH` 行都没有」+「GitHub deliveries 显示 502 且响应头为空」+「nginx access/error 日志无对应请求」。此时**不要再去改 receiver.py**，那是「收到之后」的环节；靠 watchdog 轮询兜底，或手动补部署。两者别混：有 `PUSH` 无 `DEPLOY OK` 才是队列/构建问题。

## 七、本地开发环境（2026-10-29 迁移定稿）

工作区 `E:\Users\workbuddy\2026-09-30-12-05-35\`：

| 目录 | 仓 | 分支 |
|---|---|---|
| `eyetoolkit/` | eyetoolkit/eyetoolkit 主站 | restore/chinese-v1（克隆默认在 main，需手动检出生产分支） |
| `blog/` | eyetoolkit/blog | master |
| `ops-platform/` | eyetoolkit/ops-platform | main |
| `eyetoolkit-consensus/` | eyetoolkit/eyetoolkit-consensus | main |
| `clinic/` | eyetoolkit/clinic | main |

主站本地预览：`npm run dev`（依赖已装，`npm run build` 已验证通过）。
服务器磁盘：2026-10-29 深度清理后可用 21G（47%）。`/opt/_build_` 构建缓存已于当日清空
（开发全在本地，构建只走 webhook；首次部署会自动浅拉仓+装依赖，比平时慢约 3~5 分钟）。
