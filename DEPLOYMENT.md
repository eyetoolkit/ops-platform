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

健康自检：9 个入口全 200（主站/consensus/wiki/drugs/exam/knowledge/life/blog/clinic）。

## 五、排障手册（按症状）

| 症状 | 原因 → 处置 |
|---|---|
| FAIL rc=1 in 3~4s | 构建仓被未跟踪文件挡 checkout → 删除残留（如 package-lock.json）重跑 |
| FAIL 带 ETXTBSY/ENOTEMPTY | npm 竞态 → 脚本已自动重试；仍败则 `rm -rf /opt/_build_/<profile>/repo/sites/*/node_modules` 重跑 |
| `vitepress: not found` / ESM export 报错 | node_modules 损坏 → 同上清理重跑 |
| 部署成功但线上没变化 | 推的分支不在映射表（IGNORE）；或改的是本地没 push；或看错了线上页（首页导航是 page.tsx 内联，SiteNav 只在子页面） |
| FAIL 带断言/artifact 缺失 | 看 webhook-deploy.log 的 `::error::` 行定位 |

手动兜底部署（webhook 失效时）：
```bash
ssh root@101.96.194.237   # 密钥 ~/.ssh/game_ed25519
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
服务器磁盘：深度清理后可用约 15G；`/opt/_build_` 5.7G 是构建缓存，勿当垃圾清。
