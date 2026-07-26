# lx-music-api（Cloudflare Workers）

给 **LX Music iOS** 用的精简云端：账号、管理员、云端歌单、歌单导入。  
**不负责** 搜索 / 播放 URL / 歌词（App 本地 + 用户导入的自定义源完成）。

## App 对接（`CloudApiClient`）

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 健康检查 |
| GET | `/api/ping` | 轻量 ping |
| GET | `/api/version` | 构建版本 |
| POST | `/api/user/login` | 登录 → `{ token, username, role }` |
| POST | `/api/user/register` | 注册 |
| GET/POST | `/api/user/auth/verify` | 校验 Bearer token |
| POST | `/api/user/password` | 修改密码 |
| GET | `/api/user/list` | 我喜欢 + 云端歌单 |
| POST | `/api/user/list` | 保存我喜欢 / 歌单 |
| DELETE | `/api/user/playlist?id=` | 删除歌单 |
| POST | `/api/user/playlist/refresh` | 刷新导入歌单 |
| POST | `/api/user/love/add` | 添加收藏 |
| POST | `/api/user/love/remove` | 移除收藏 |
| POST | `/api/music/playlist/import` | 导入预览 / 保存（QQ / 酷我 / 网易） |
| * | `/api/admin/users` | 管理员用户 CRUD |

App 路径：**设置 → 云端账号 / 歌单**，填写 `https://lx-music-api.<account>.workers.dev`。

## 自动部署

推送 `main` 且改动 `workers/`，或手动运行 **Deploy Workers API**：

`.github/workflows/deploy-workers.yml`

| Secret | 说明 |
|--------|------|
| `CLOUDFLARE_API_TOKEN` | Workers 编辑权限 |
| `CLOUDFLARE_ACCOUNT_ID` | Account ID |
| `D1_DATABASE_ID` | D1 库 ID |
| `KV_NAMESPACE_ID` | KV 命名空间 ID |
| `ADMIN_USERNAME` | 管理员用户名 |
| `ADMIN_PASSWORD` | 管理员密码 |

## 本机首次准备

```bash
cd workers
npm install
npx wrangler d1 create lx-music-api
npx wrangler kv namespace create CACHE
# 把 id 写入 GitHub Secrets 或 wrangler.toml
npx wrangler secret put ADMIN_USERNAME
npx wrangler secret put ADMIN_PASSWORD
npm run deploy
```

本地调试：`npm run dev`  
类型检查：`npm run typecheck`

## 绑定

- **D1** `DB`：用户、歌单、设置  
- **KV** `CACHE`：缓存  
- **Durable Object** `RateLimiterDO`：登录限流（SQLite class，免费套餐）  
- `workers_dev = true`：启用 `*.workers.dev` 路由  
