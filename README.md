# LX Music for iOS

一个使用 Flutter 构建的 iOS 音乐查找与播放应用。项目内置 QQ 音乐、酷我音乐和网易云音乐适配，并兼容 LX Music Mobile `v2` 风格的 JavaScript 自定义音源。

> 本项目是音乐查找与播放客户端，不提供或托管音乐内容。搜索结果、播放地址、歌词和封面均来自用户配置的服务或第三方平台，稳定性与可用性取决于对应服务。

## 当前功能

- QQ 音乐、酷我音乐、网易云音乐搜索与榜单
- 单曲、歌单、收藏、最近播放和重复歌曲管理
- 顺序播放、单曲循环、随机播放和分页大歌单
- `128k`、`320k`、FLAC、24-bit FLAC、Hi-Res 音质选择
- LRC、QRC、LRCX 和逐字歌词显示
- 后台播放、锁屏控制、耳机中断处理和拔出暂停
- iOS 主屏幕小组件与 `lxmusic://nowplaying` 深链
- 下载队列、断点状态恢复、失败重试和本地文件播放
- 播放统计与基于收藏/历史的本地推荐
- JSON 数据备份与事务式恢复
- 可选 Cloudflare Workers 账号与歌单同步服务
- LX Music Mobile 自定义音源导入、编辑、启用、日志和导出
- 浅色、深色和跟随系统主题

应用包含四个主导航分支：主页、搜索、歌单和设置。全屏播放器、下载、自定义源、同步、统计、重复歌曲和推荐使用独立路由。

## 播放机制

### URL 与音质解析

播放解析从用户选择的音质开始，按以下顺序逐级降级：

```text
Hi-Res -> 24-bit FLAC -> FLAC -> 320k -> 192k -> 128k
```

每个候选音质会先尝试已启用的自定义源，再尝试对应平台的内置适配。返回结果会记录请求音质、实际音质、真实解析平台和源侧歌曲 ID；全屏播放器底部展示实际解析平台与实际音质。

当前平台全部失败后，应用只会在以下三个平台之间搜索同名同歌手歌曲并自动回退：

```text
tx (QQ) <-> kw (酷我) <-> wy (网易云)
```

回退不会递归执行。`kg`、`mg` 和 `local` 可作为自定义源脚本平台标识，但不属于内置自动切换范围。

### 播放缓存

解析成功后优先下载到应用支持目录中的播放缓存。缓存默认：

- 最长保留 3 天
- 最大容量 1 GiB
- 缓存键为 `SHA-1(platform|songId|quality)`
- 使用临时文件下载，验证文件头后原子提交
- 按租约保护正在播放或已预加载的文件
- 过期和容量清理由未占用文件开始

有损音质在完整缓存失败后，可以通过 Range 请求验证后直接流式播放；无损音质不会走该流式降级路径。持久化的远程签名 URL 不会在重启后直接复用，避免过期地址导致播放失败。

### 预加载

当前歌曲成功安装到播放器后，后台预加载后续歌曲：

- Wi-Fi 或以太网：3 首
- 其他网络或网络状态检测失败：2 首

预加载会执行完整的 URL 解析、音质选择、媒体验证和缓存流程，但不阻塞当前播放。结果绑定播放代次、队列 occurrence 和请求 token，过期结果不能覆盖当前歌曲。相同缓存键的并发下载会在缓存层合并。

队列中同一歌曲的不同 occurrence 仍会分别发起解析，因此重复歌曲可能产生重复的音源查询，但通常不会重复下载同一个缓存文件。

### 短音频拒绝

播放器加载媒体后，如果底层返回的实际时长小于 15 秒，该地址会被视为解析失败并立即停止。恰好 15 秒的音频允许播放。

部分远程媒体在安装时无法立即提供时长；底层返回未知时长时不会提前拒绝。

### 大歌单

大歌单使用懒加载播放窗口：

- 每页 100 首
- 前向保持最多 8 首
- 保留最多 4 首历史歌曲
- 解码页缓存最多保留 4 页

队列 occurrence 用于区分 ID 相同的重复歌曲，避免异步解析结果写入错误的队列位置。

## 歌词

歌词服务支持：

- 标准 LRC
- 腾讯 QRC
- LRCX 逐字标签
- 网易云 YRC 转换结果
- 酷我纯毫秒行标签
- 翻译歌词配对
- 全局歌词偏移

应用优先保留内置平台返回的逐字歌词，失败后再尝试自定义源和跨平台匹配。歌词使用内存 TTL 缓存；缺少逐字信息的缓存不会阻止后续重新获取更完整的歌词。

## LX 自定义音源

自定义源支持本地 `.js` 文件、URL、粘贴内容、JSON 导入和手动创建。单个脚本上限为 2 MiB，同一时间通常只启用一个源。

运行时对齐 LX Music Mobile `v2` 常用接口，包括：

- `lx.on('request', handler)`
- `lx.send('inited', data)`
- `lx.request`
- `lx.currentScriptInfo`
- Buffer、加解密、压缩、定时器和常用 Web/Node 兼容接口

脚本可声明的平台包括 `kw`、`kg`、`tx`、`wy`、`mg` 和 `local`，媒体能力包括 `musicUrl`、`lyric` 和 `pic`。

### 运行时安全边界

- 导入和启动时检测已知的同步无限扩容循环
- 禁止脚本动态 `eval` 和 `Function` 构造
- 冻结宿主对象和关键全局属性
- 单请求响应上限 10 MiB
- 总保留响应数据上限 20 MiB
- 最多 4 个并发请求和响应体
- 请求和初始化均有超时
- reload/dispose 时取消在途请求

自定义脚本仍与应用进程共享 JavaScriptCore，不具备独立进程、CPU 配额或可中断的同步执行。静态检测只覆盖已知危险模式，无法证明任意第三方脚本安全。只应导入可信来源的脚本。

## 网络策略

自定义源请求支持 HTTP 和 HTTPS，并对每一跳执行 URL 与地址检查：

- 拒绝 URL 凭据
- 拒绝私网、回环、链路本地和保留地址
- 限制重定向次数、响应大小和并发量
- 跨源重定向移除授权、Cookie 和敏感请求头
- iOS 使用基于已校验地址的 pinned transport，避免校验后再次 DNS 解析

播放媒体允许 HTTP 地址，因为部分音源返回明文媒体 CDN URL；iOS ATS 仅为媒体加载启用了对应例外。

## 数据与存储

- 设置、自定义源、下载任务、播放会话、统计和缓存索引：SharedPreferences
- 云端登录令牌：Keychain (`flutter_secure_storage`)
- 歌单与下载文件：Application Documents
- 播放缓存与封面缓存：Application Support
- 小组件状态：App Group `group.com.lxmusic.lxMusicFlutter`

歌单仓库使用当前文件、临时文件、上一版本和恢复文件进行原子保存与损坏恢复。备份文件使用版本化 JSON，并在恢复前限制文件大小、JSON 复杂度、歌单数量和歌曲数量。

当前备份只包含歌单、搜索历史、主题、播放音质、下载音质、Wi-Fi 下载设置、自动恢复播放和默认搜索平台，不包含自定义源、播放统计、云端账号、下载文件或完整播放会话。

## iOS 集成

- 主应用最低部署目标：iOS 13.0
- Widget Extension 最低部署目标：iOS 16.1
- 后台音频模式
- AudioSession 中断和耳机拔出处理
- 锁屏/控制中心媒体信息
- 主屏幕小组件
- App Group 文件共享
- 缓存文件保护属性调整，支持锁屏后继续读取
- `lxmusic://nowplaying` 深链

仓库只包含 iOS host 工程，没有 Android、Web、macOS、Windows 或 Linux host。

## 开发环境

建议使用与当前依赖图一致的环境：

- Flutter 3.44.x
- Dart 3.12.x
- Xcode 与 iOS SDK
- CocoaPods 1.16.x
- macOS（运行或构建 iOS 必需）

根 `pubspec.yaml` 已声明 Dart `>=3.12.0` 和 Flutter `>=3.44.0`，与当前依赖图一致。

安装依赖：

```bash
flutter pub get
cd ios
pod install
cd ..
```

运行：

```bash
flutter devices
flutter run -d <device-id>
```

静态分析与测试：

```bash
flutter analyze
flutter test
```

`flutter test --exclude-tags live` 运行不依赖真实平台的确定性测试；未排除 `live` 时还会执行真实平台网络请求，可能受第三方接口状态影响。

构建未签名 iOS 应用：

```bash
flutter build ios --release --no-codesign
```

构建签名 IPA：

```bash
flutter build ipa --release
```

GitHub Actions 生成一个未签名产物 `LX-Music-Apple-ID-Sideload-IPA`，该包移除了 Widget Extension，适合使用爱思助手、Sideloadly 或 AltStore 通过 Apple ID 重新签名安装。未签名 IPA 不能直接安装到普通未越狱设备。

签名构建需要为主应用和 Widget Extension 配置相同团队、正确的 bundle identifier、App Group、后台音频和 Widget/Live Activities 能力。使用 Xcode 时应打开：

```bash
open ios/Runner.xcworkspace
```

## Cloudflare Workers（可选）

`workers/` 提供可选的账号、歌单同步和平台 API 服务，依赖：

- Node.js 20+
- Cloudflare Workers
- D1 数据库
- KV Namespace
- SQLite-backed Durable Object
- Wrangler

本地校验：

```bash
cd workers
npm ci
npm run validate
```

本地开发：

```bash
npm run dev
```

部署前需要在 `workers/wrangler.toml` 中配置 D1/KV ID、应用 migrations，并设置：

```bash
npx wrangler secret put ADMIN_USERNAME
npx wrangler secret put ADMIN_PASSWORD
```

GitHub Actions 的 Workers workflow 还需要 `CLOUDFLARE_API_TOKEN`、`CLOUDFLARE_ACCOUNT_ID`、`D1_DATABASE_ID` 和 `KV_NAMESPACE_ID`。

## CI

- `build-ios.yml`：在 `macos-15` 和 Flutter `3.44.7` 上执行 analyze、确定性测试，并构建未签名 IPA，产物保留 7 天
- `deploy-workers.yml`：类型检查、Vitest、结构检查、D1 migration、Workers 部署和健康/登录验证

iOS 构建仍需要 macOS、Xcode、CocoaPods 和有效的 Apple 工程环境；Linux 上只能完成 Dart/Flutter 静态检查与测试。

## 目录结构

```text
lib/
  core/
    audio/          播放协调、缓存、预加载和音频运行时
    music_source/   QQ/酷我/网易云内置平台适配
    network/        URL、媒体和自定义源请求策略
    storage/        偏好设置与安全令牌
  features/
    custom_source/  LX JavaScript 音源运行时
    download/       下载队列与文件管理
    lyric/          歌词获取、解析和显示
    player/         播放器、会话恢复和锁屏同步
    playlist/       歌单、导入、分页和重复检测
    search/         搜索与历史
    settings/       设置、备份和恢复
    stats/          播放统计
    sync/           云端账号与歌单同步
ios/
  Runner/           iOS 主应用
  WidgetExtension/  WidgetKit / ActivityKit 扩展
workers/            Cloudflare Workers 可选服务
test/               Dart 与 Flutter 测试
```

## 已知限制

- 自定义源脚本没有进程级隔离；恶意同步代码仍可能阻塞 JavaScriptCore
- 自定义源搜索与远端歌单能力仍处于兼容性完善阶段
- 预加载对重复歌曲按 occurrence 解析，可能重复调用音源接口
- 启动恢复不会恢复播放位置、循环模式或随机模式
- 小于 15 秒检查依赖播放器在安装源时返回实际时长
- 云端拉取是覆盖式同步，操作前应确认远端内容完整
- 备份不等同于完整应用数据导出
- 完整测试包含真实网络平台，无法保证离线确定性

## 免责声明

请遵守所在地法律法规、平台服务条款和内容版权要求。项目仅用于技术研究和个人学习；使用第三方音源脚本、接口和媒体地址所产生的风险由使用者自行承担。
