# LX2IOS

<p align="center">
  <img src="assets/icon/app_icon.png" width="96" alt="LX Music">
</p>

<p align="center">
  <b>洛雪风格的 iOS 音乐客户端</b><br>
  Flutter · 自定义音源 · 可选 Cloudflare 云端
</p>

<p align="center">
  <a href="#功能"><img src="https://img.shields.io/badge/平台-iOS-black?style=flat-square" alt="iOS"></a>
  <a href="#技术栈"><img src="https://img.shields.io/badge/Flutter-3.x-02569B?style=flat-square&logo=flutter&logoColor=white" alt="Flutter"></a>
  <a href="#云端-workers"><img src="https://img.shields.io/badge/Cloudflare-Workers-F38020?style=flat-square&logo=cloudflare&logoColor=white" alt="Workers"></a>
  <a href="#许可与声明"><img src="https://img.shields.io/badge/用途-学习自用-red?style=flat-square" alt="学习自用"></a>
</p>

> **个人学习与自用项目，请勿大规模分发。**  
> 基于 [yingjunda/LX-Music-Flutter-Mobile](https://github.com/yingjunda/LX-Music-Flutter-Mobile) 改造，面向 iOS 精简与增强。

---

## 目录

- [功能](#功能)
- [技术栈](#技术栈)
- [播放链路](#播放链路)
- [仓库结构](#仓库结构)
- [快速开始](#快速开始)
- [构建 iOS](#构建-ios)
- [云端 Workers](#云端-workers)
- [开发](#开发)
- [文档](#文档)
- [许可与声明](#许可与声明)

---

## 功能

### App

| 模块 | 说明 |
|------|------|
| **搜索 / 排行榜** | QQ（腾讯）· 酷我 · 网易云 |
| **播放** | 后台播放、锁屏控件、全屏封面/歌词、迷你播放栏、音质（默认 320k） |
| **播放解析** | 优先**已启用自定义源脚本**；失败再回退内置 `tx` / `kw` / `wy` 官方接口 |
| **自定义源** | 导入洛雪脚本；无其它启用源时自动启用；可删可改 |
| **本地歌单** | 我喜欢、最近播放、自建歌单；库内搜歌 |
| **主题** | 默认跟随系统；深色纯黑 + 绿色强调 / 浅色 |
| **云端** | 设置 →「云端账号 / 歌单」：Workers 地址、登录注册、拉/导歌单、管理员 |


---

## 技术栈

| 层 | 选型 |
|----|------|
| UI / 业务 | Flutter · Riverpod · go_router |
| 音频 | just_audio · audio_service |
| 自定义源 | flutter_js（执行洛雪脚本） |
| 网络 / 存储 | dio · shared_preferences · path_provider |
| 云端（可选） | Cloudflare Workers · D1 · KV · Durable Objects |

---

## 仓库结构

```
LX2IOS/
├── ios/                      # Xcode / CocoaPods 工程
├── lib/                      # Flutter 业务代码
│   ├── core/                 # 核心能力
│   ├── features/             # 功能模块
│   └── router/               # 路由
├── workers/                  # Cloudflare Workers（账号 / 歌单）
├── assets/icon/              # App 图标
├── docs/                     # 隐私政策、用户协议等
├── test/                     # 测试
└── .github/workflows/
    ├── build-ios.yml         # 未签名 IPA
    └── deploy-workers.yml    # Workers 自动部署
```

---

## 快速开始

### 环境要求

- Flutter **3.x**（stable，SDK `>=3.2.0 <4.0.0`）
- Xcode + CocoaPods
- 真机或模拟器

### 运行

```bash
git clone https://github.com/kiseding/LX2IOS.git
cd LX2IOS

flutter pub get
cd ios && pod install && cd ..

flutter run -d <device>
```

### 可选：连接云端

1. 部署 [Workers](#云端-workers)（或使用已有实例）
2. App → **设置 → 云端账号 / 歌单**
3. 填写 `https://lx-music-api.<账号>.workers.dev`
4. 登录 / 注册 → 拉取或导入歌单

---

## 构建 iOS

### 本机

```bash
flutter pub get
cd ios && pod install && cd ..
flutter build ios --release --no-codesign
```

### CI（推荐）

推送 `main` 或手动触发 **Build unsigned IPA**：

| 项 | 值 |
|----|-----|
| Workflow | `.github/workflows/build-ios.yml` |
| Runner | `macos-15` |
| Flutter | `3.44.7` stable |
| 产物 | Artifact `LX-Music-unsigned-IPA`（保留 7 天） |

未签名 IPA 需自行用企业/个人证书或 AltStore 等侧载工具安装。

---

## 云端 Workers

可选后端，**只负责**账号与歌单，不碰音源。

| 能力 | 说明 |
|------|------|
| 账号 | 登录 / 注册 / Token / 改密 |
| 管理 | 管理员用户 CRUD |
| 歌单 | 云端「我喜欢」、自建歌单 |
| 导入 | QQ / 酷我 / 网易（链接或 ID） |

完整接口见 [`workers/README.md`](./workers/README.md)。

### 自动部署

推送 `main` 且改动 `workers/`，或手动 **Deploy Workers API**。

| Secret | 说明 |
|--------|------|
| `CLOUDFLARE_API_TOKEN` | Workers 编辑权限 |
| `CLOUDFLARE_ACCOUNT_ID` | Account ID |
| `D1_DATABASE_ID` | D1 数据库 ID |
| `KV_NAMESPACE_ID` | KV 命名空间 ID |
| `ADMIN_USERNAME` | 管理员用户名 |
| `ADMIN_PASSWORD` | 管理员密码 |

### 本机部署

```bash
cd workers
npm install

# 首次
npx wrangler d1 create lx-music-api
npx wrangler kv namespace create CACHE
# 将 id 写入 wrangler.toml 或 GitHub Secrets

npx wrangler secret put ADMIN_USERNAME
npx wrangler secret put ADMIN_PASSWORD
npm run deploy
```

本地调试：`npm run dev` · 类型检查：`npm run typecheck`

---

## 开发

```bash
# App
flutter pub get
flutter run -d <device>
flutter test

# Workers
cd workers
npm run typecheck
npm run dev
```

---

## 文档

| 文档 | 说明 |
|------|------|
| [`workers/README.md`](./workers/README.md) | Workers API 与部署 |
| [`docs/privacy-policy.md`](./docs/privacy-policy.md) | 隐私政策 |
| [`docs/user-agreement.md`](./docs/user-agreement.md) | 用户协议 |

---

## 许可与声明

- **仅供学习与个人使用**，请勿用于商业或大规模分发。
- 音乐版权归各平台所有，请支持正版。
- 自定义音源脚本由用户自行导入，其可用性与合法性由用户自行负责。
- 上游参考：[lyswhut/lx-music-desktop](https://github.com/lyswhut/lx-music-desktop) · [yingjunda/LX-Music-Flutter-Mobile](https://github.com/yingjunda/LX-Music-Flutter-Mobile)

---

<p align="center">
  <sub>LX2IOS · iOS Music Shell</sub>
</p>
