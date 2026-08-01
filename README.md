# LX2IOS

<p align="center">
  <img src="assets/icon/app_icon.png" width="96" alt="LX Music">
</p>

<p align="center">
  <b>洛雪风格的 iOS 音乐客户端</b><br>
  Flutter · 自定义音源 · 可选 Cloudflare 云端
</p>

<p align="center">
  <a href="#完整功能说明"><img src="https://img.shields.io/badge/平台-iOS-black?style=flat-square" alt="iOS"></a>
  <a href="#ipa安装"><img src="https://img.shields.io/badge/Flutter-3.x-02569B?style=flat-square&logo=flutter&logoColor=white" alt="Flutter"></a>
  <a href="#workers部署方式"><img src="https://img.shields.io/badge/Cloudflare-Workers-F38020?style=flat-square&logo=cloudflare&logoColor=white" alt="Workers"></a>
  <a href="#免责声明和不可商用许可证"><img src="https://img.shields.io/badge/用途-学习自用-red?style=flat-square" alt="学习自用"></a>
</p>

> **个人学习与自用项目，禁止商用、禁止大规模分发。**
> 基于 [yingjunda/LX-Music-Flutter-Mobile](https://github.com/yingjunda/LX-Music-Flutter-Mobile) 改造，面向 iOS 精简与增强。

---

## 目录

- [完整功能说明](#完整功能说明)
- [ipa安装](#ipa安装)
- [workers部署方式](#workers部署方式)
- [鸣谢](#鸣谢)
- [免责声明和不可商用许可证](#免责声明和不可商用许可证)

---

## 完整功能说明

### 音乐搜索与发现

| 模块 | 说明 |
|------|------|
| **搜索** | 支持「全网 / QQ 音乐 / 酷我 / 网易云」多平台切换，分页加载更多；保存最近 20 条搜索历史；酷我热榜兜底展示 |
| **排行榜** | 首页按平台（QQ / 酷我 / 网易）展示榜单卡片，进入榜单查看歌曲列表，点击即可播放 |
| **歌单搜索** | 支持搜索歌单并查看歌单内歌曲详情 |
| **猜你喜欢** | 基于「收藏列表」的内容推荐：收藏满 100 首后每次随机取样 100 首建立画像，固定推荐 30 首并给出推荐理由（常听歌手 / 专辑 / 近期常听） |

### 播放

| 模块 | 说明 |
|------|------|
| **播放引擎** | just_audio + audio_service，支持后台播放、锁屏媒体控件、无缝自动下一首 |
| **播放模式** | 顺序播放 / 单曲循环 / 随机播放 |
| **全屏播放器** | 上下滑动关闭；封面页 + 全屏歌词页两页切换；封面点击进歌词页 |
| **迷你播放栏** | 底部悬浮栏：进度、上一首 / 播放暂停 / 下一首，点击展开全屏播放器，实时歌词一行 |
| **音质选择** | 标准 128k / 超高品质 320k / 无损 FLAC / 臻品母带 FLAC 24bit / Hi-Res；播放时按质量重新解析 |
| **播放队列** | 底部弹出队列，支持大型歌单分页浏览、跳页，点击切换歌曲 |
| **睡眠定时** | 设置 → 播放 → 睡眠定时：10 / 15 / 30 / 60 / 90 分钟，倒计时显示、可取消、失败自动重试 |
| **自动恢复播放** | 打开 App 时自动继续播放上次歌曲（可关闭） |
| **会话恢复** | 启动时恢复上次播放队列与位置，切换稳定性优化 |
| **音频中断处理** | 来电 / 其他 App 打断时自动暂停，通话结束后按原状态恢复；拔出耳机自动暂停 |

### 自定义音源

- 完整兼容洛雪（LX Music desktop）脚本引擎（`flutter_js` 执行）：
  - `lx.request` / `lx.send` / `lx.on` 事件流与多处理器
  - `lx.utils`：MD5、AES-CBC/ECB、RSA、zlib、Buffer、`atob/btoa`、`setTimeout`
- **能力声明校验**：拒绝脚本声明外的动作 / 音质，避免越权行为
- **SSRF 加固沙箱**：仅允许 HTTPS、解析后拦截内网 / 私网 IP（IPv4 + IPv6）、DNS 固定 TCP + TLS SNI、拦截代理与重定向、限制并发与字节数
- 导入方式：本地 `.js` 文件、HTTPS 链接、**剪切板链接**、粘贴脚本（洛雪脚本或 JSON 配置）
- 管理：启用 / 禁用（同时仅启用一个）、导出 JSON、删除、运行日志控制台、去重、单脚本 2MB 上限
- 播放链路：优先使用已启用的自定义源脚本解析；失败后回退内置 `tx` / `kw` / `wy` 官方接口

### 本地歌单

| 模块 | 说明 |
|------|------|
| **收藏列表** | 内置收藏歌单，全 App 内可收藏 / 取消收藏，支持批量添加 |
| **最近播放** | 自动记录最近播放歌曲 |
| **自建歌单** | 创建、编辑、删除、重命名、描述；支持手动排序与按名称 / 歌手 / 时长排序 |
| **歌单详情** | 全部播放、单曲播放、从歌单移除、分页加载 |
| **重复歌曲** | 检测重复版本，自动保留最优版本，批量清理 |
| **歌单导入** | 支持粘贴 QQ / 酷我 / 网易分享链接或 ID 导入歌单 |
| **库内搜索** | 在本地歌单内搜索歌曲 |

### 歌词

- 支持 **LRC / LRCX 逐字时间轴 / QRC / 腾讯 QRC 与咪咕 MRC 字词标签**、`[offset:]` 偏移
- **本地歌词翻译**：同一时间戳的相邻原文 / 译文自动配对展示（在线翻译接口已移除）
- **KTV 逐字卡拉 OK**：歌词按字逐词填色；自动滚动、点击定位到对应时间点播放
- 歌词来源：自定义源脚本优先，失败回退内置平台接口，带 TTL 缓存

### 下载与离线播放

- 下载管理：进行中 / 已完成 / 全部三个标签，汇总进度卡片（速度 / 大小 / 数量）
- 每个任务支持暂停 / 继续 / 重试 / 取消 / 删除；可全部暂停、清空已完成
- 三路并发、**仅 WiFi 下载**、下载音质可独立选择
- 始终重新解析新鲜播放地址（不复用过期的 CDN 链接）；部分文件 + 原子改名落盘
- 校验 HTML / 非音频内容并拒绝；任务持久化，异常中断自动恢复
- 已下载歌曲支持 **离线播放**（`file://`）

### 听歌统计

- 时间范围：本周 / 本月 / 今年 / 全部
- 汇总卡片：播放次数、听歌时长、活跃天数、听过歌曲数
- 每日播放热力图、Top 20 歌曲 / 歌手 / 专辑
- 播放历史流水记录（30 秒以上计一次、上限 5000 条、防抖落盘）

### 云端同步（可选）

- 对接自带 Cloudflare Workers 后端：登录 / 注册 / Token / 改密
- 云端「收藏列表」与自建歌单：拉取、合并、导出
- 管理员用户管理（增删改查、重置密码）
- 密钥仅存 Keychain（按来源隔离，兼容旧 Token 迁移）

### 数据与主题

| 模块 | 说明 |
|------|------|
| **主题** | 深色 / 浅色 / 跟随系统；深色纯黑 + 强调色 |
| **数据备份** | 导出歌单、设置、搜索历史到 JSON 文件 |
| **数据恢复** | 从备份文件恢复，事务式写入、回滚保护、大小限制 |
| **清除缓存** | 清理下载缓存与临时文件 |
| **安全存储** | Keychain 存储 Token，存储层带写入校验 / 快照 / 回滚 |

### iOS 小组件

- **主屏幕小组件**（小 / 中尺寸）：正在播放卡片——封面、歌名 / 歌手、播放状态、进度条；无数据时显示引导入口；点击卡片经 `lxmusic://` 深链回到播放器
- 数据经 App Group `group.com.lxmusic.lxMusicFlutter` 同步（主 App 与 WidgetExtension 双端 entitlement）
- 说明：灵动岛 Live Activity 代码保留，但运行时已停用，锁屏统一走 iOS 系统 Now Playing 表面

### 其它

- 底部四 Tab：首页 / 搜索 / 歌单 / 设置，支持左右滑动切换
- 音源解析采用「自定义源 → 内置平台」链路，内置平台自动跨平台回退
- 无障碍支持：核心控件语义、键盘 / 焦点 / 快捷键操作

---

## ipa安装

本仓库提供**未签名 IPA** 的自动化构建产物。未签名 IPA 需要自行签名后安装。

### 方式一：GitHub Actions 构建

推送 `main` 或手动触发 **Build unsigned IPA**：

| 项 | 值 |
|----|-----|
| Workflow | `.github/workflows/build-ios.yml` |
| Runner | `macos-15` |
| Flutter | `3.44.7` stable |
| 命令 | `flutter build ios --release --no-codesign` |
| 产物 | Artifact `LX-Music-unsigned-IPA`（保留 7 天） |

1. 进入仓库 **Actions** 页，运行 **Build unsigned IPA**
2. 在完成后的摘要中下载 `LX-Music-unsigned-IPA` 工件，解压得到 `LX-Music-unsigned.ipa`

### 方式二：本机构建

```bash
git clone https://github.com/kiseding/LX2IOS.git
cd LX2IOS

flutter pub get
cd ios && pod install && cd ..

flutter build ios --release --no-codesign
```

产物在 `build/ios/iphoneos/Runner.app`；可自行打包为 `.ipa`：

```bash
mkdir -p build/ios/ipa-unsigned/Payload
ditto build/ios/iphoneos/Runner.app build/ios/ipa-unsigned/Payload/Runner.app
(
  cd build/ios/ipa-unsigned
  ditto -c -k --sequesterRsrc --keepParent Payload ../LX-Music-unsigned.ipa
)
```

### 方式三：爱思助手 Apple ID 签名安装

1. 将未签名 `.ipa` 导入爱思助手（或连接设备后选择「导入安装」）
2. 选择**Apple ID 签名**，输入 Apple ID / 密码（可使用专用密码），等待自动签名
3. 签名完成后安装到设备；首次打开需在「设置 → 通用 → VPN 与设备管理」中信任开发者证书
4. 安装后需要在系统设置中给 App 开启**后台播放**等权限

> **注意：Apple ID 免费签名的能力限制**
> - 桌面小组件需要主 App 与 WidgetExtension 双端持有 **App Groups** 能力。爱思 Apple ID 重签通常无法为你的 Team 签发包含该 App Group 的 provisioning profile，因此 **小组件可能无法读取实时播放数据**，仅能显示引导占位。
> - 如需完整小组件与灵动岛能力，请使用付费 Apple Developer 账号，为 `Runner` 与 `WidgetExtension` 都开启 App Group `group.com.lxmusic.lxMusicFlutter` 后重新签名。
> - 免费签名有效期为 7 天，过期后需重新签名安装。

---

## workers部署方式

可选云端后端（`workers/`），**只负责账号与云端歌单，不负责音源**。搜索 / 播放 URL / 歌词由 App 本地与用户导入的自定义源完成。

### 能力范围

| 能力 | 说明 |
|------|------|
| 账号 | 登录 / 注册 / Token / 改密 / 校验 |
| 管理 | 管理员用户 CRUD、重置密码 |
| 歌单 | 云端「收藏列表」、自建歌单（拉取 / 合并 / 导出 / 删除 / 刷新） |
| 导入 | QQ / 酷我 / 网易（链接或 ID，两阶段预览 / 保存） |

### 技术栈

- **D1**（用户、歌单、设置、播放进度）+ **KV**（缓存）+ **Durable Object**（登录限流）
- CORS、`X-Request-ID` 请求关联、日志采样 10% / 链路采样 1%

### 方式一：GitHub Actions 自动部署

推送 `main` 且改动 `workers/`，或手动运行 **Deploy Workers API**。

先在仓库 **Settings → Secrets and variables → Actions** 配置：

| Secret | 说明 |
|--------|------|
| `CLOUDFLARE_API_TOKEN` | Workers 编辑权限 |
| `CLOUDFLARE_ACCOUNT_ID` | Account ID |
| `D1_DATABASE_ID` | D1 数据库 ID |
| `KV_NAMESPACE_ID` | KV 命名空间 ID |
| `ADMIN_USERNAME` | 管理员用户名 |
| `ADMIN_PASSWORD` | 管理员密码 |

CI 会自动执行：类型检查 → 单元测试 → 结构校验 → 打版本号 → 应用 D1 迁移 → `wrangler deploy` → 推送管理员密钥 → 健康检查与登录验证。

### 方式二：本机部署

```bash
cd workers
npm install

# 首次准备（创建 D1 与 KV，并把 id 写入 wrangler.toml 或 GitHub Secrets）
npx wrangler d1 create lx-music-api
npx wrangler kv namespace create CACHE

# 应用数据库迁移
npx wrangler d1 migrations apply lx-music-api --local

# 配置管理员密钥
npx wrangler secret put ADMIN_USERNAME
npx wrangler secret put ADMIN_PASSWORD

# 部署
npm run deploy
```

本地调试：`npm run dev` · 类型检查：`npm run typecheck`

### App 对接

1. 部署完成后得到 `https://lx-music-api.<账号>.workers.dev`
2. App → **设置 → 同步 → 云端账号 / 歌单**
3. 填写 Workers 地址（HTTPS 校验 + 健康检查），登录 / 注册
4. 拉取或合并云端歌单

### D1 迁移注意事项

- Schema 变更只通过 `workers/migrations/` 在部署时执行，请求路径不跑 DDL。
- 生产迁移：`npx wrangler d1 migrations apply lx-music-api --remote`（CI 会在部署前自动执行）。
- 旧库缺少 `users.token_version` 时，需先手动补丁：

```bash
npx wrangler d1 execute lx-music-api --remote \
  --command "ALTER TABLE users ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0"
```

- 未完成迁移时，除 `/api/ping` 与 `/api/version` 外的 `/api/*` 返回 **503**。

完整接口见 [`workers/README.md`](./workers/README.md)。

---

## 鸣谢

本项目基于与参考了以下开源项目，特此致谢：

- [yingjunda/LX-Music-Flutter-Mobile](https://github.com/yingjunda/LX-Music-Flutter-Mobile) —— 本项目的基础（Flutter 移动端实现）
- [lyswhut/lx-music-desktop](https://github.com/lyswhut/lx-music-desktop) —— 自定义音源脚本规范与设计参考
- [chenqi92/primuse](https://github.com/chenqi92/primuse) —— Live Activity / 灵动岛 / 小组件实现参考
- [NicolasHug/Surprise](https://github.com/NicolasHug/Surprise) —— 「猜你喜欢」推荐引擎思路参考
- [Flutter](https://flutter.dev) 与 [just_audio](https://pub.dev/packages/just_audio) / [audio_service](https://pub.dev/packages/audio_service) 等开源依赖

如果本项目侵犯了任何项目的版权，请联系作者删除。

---

## 免责声明和不可商用许可证

### 免责声明

1. **学习用途**：本项目仅用于个人学习、技术研究与非商业用途。
2. **内容来源**：本客户端不直接提供任何音乐内容。所有歌曲、封面、歌词等资源均来自用户自行配置的音乐平台接口或用户导入的自定义音源脚本。本项目不保存、不上传、不传播任何音乐文件。
3. **版权归属**：音乐版权归各音乐平台与版权方所有，请支持正版。因使用本项目获取资源所产生的版权问题，由使用者自行承担。
4. **自定义源责任**：自定义音源脚本由用户自行导入并执行，其可用性、稳定性与合法性由用户自行负责。项目对脚本行为做了沙箱与安全限制，但不对脚本提供的内容负责。
5. **服务稳定性**：本项目及可选云端 Workers 服务按「现状」提供，不对可用性、准确性或中断做任何保证；使用本服务产生的一切后果由使用者自负。
6. **与本项目无关的损失**：任何因使用本项目（包括但不限于侧载安装、重签名、账号安全、数据丢失）导致的直接或间接损失，项目作者不承担任何责任。

### 不可商用许可证

本项目采用**非商业许可**，条款如下：

> 1. 允许复制、修改、学习和个人使用本项目源代码。
> 2. **禁止将本项目或其衍生作品用于任何商业目的**，包括但不限于：
>    - 出售、出租、转授权或以任何形式收费；
>    - 在商业产品、商业 App、上架应用商店等商业场景中使用；
>    - 用于任何以盈利为目的的运营或服务。
> 3. **禁止大规模分发**本项目或其打包产物（如未签名 / 重签名 IPA）。
> 4. 修改后的衍生作品必须保留本许可与免责声明，并标注来源。
> 5. 如将本项目用于任何违反所在地区法律法规的用途，后果由使用者自行承担，作者不承担任何责任。
> 6. 作者保留对本项目的一切权利。对于违反本许可的行为，作者有权要求停止使用并删除相关内容。

**总结：个人学习与自用免费，禁止商用、禁止收费分发、禁止上架盈利。**

---

<p align="center">
  <sub>LX2IOS · iOS Music Shell</sub>
</p>
