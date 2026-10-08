# 发布包检查

这是只读检查，失败会返回非零状态。通过只代表产物检查合格，不能替代完整业务验收。

```sh
python3 tools/release-readiness/check.py \
  --app /path/to/Prosio.app \
  --report docs/evidence/release-audit-2026-10-04/artifact-check.json
```

正式构建需显式设置 `PROSIO_BACKEND_URL=https://实际生产域名`、Developer ID 身份与 Team；没有凭证时只能产出本地测试包。生产环境不可启用 `/api/auth/dev`。数据库需依次部署主表、`server/sql/meeting_jobs.sql`、`server/sql/cloud_operations.sql`，同时部署新代码；旧服务的 `/api/usage` 写入不能与新服务混跑。上线数据库前先备份并演练迁移和回滚。新 ledger 删除用户时随 users 级联删除，但响应保留期限、过期任务核查和真实多连接并发仍须完成。

回归检查：

```sh
swift test --package-path Packages/ProsioKit
xcodebuild -project Prosio.xcodeproj -scheme ProsioValidation -configuration Debug -derivedDataPath .build-release-audit test
cd server
npm ci
npm run typecheck
npm test
npx vitest run --config scripts/commercialization-audit.config.ts
npm run build
npm audit
```

数据库单测使用 PGlite 执行真实 SQL 和 PL/pgSQL。它只有一个连接，不证明 Neon 多连接、多服务实例的锁与失败恢复正确。需在隔离的真实 Postgres/Neon 环境再验证并发额度、重复提交、进程中断和网络断连。不要把测试用 JWT、开发登录或 localhost 带入公开发布包。
