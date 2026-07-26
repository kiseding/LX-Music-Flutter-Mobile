# 播放前本地缓存设计

**日期：** 2026-07-26  
**状态：** 待用户确认后实现  
**范围：** 所有在线播放先下载到本地再播；缓存保留 3 天

## 背景

iOS AVPlayer 对部分网络 FLAC/Hi-Res 流会立刻失败（如错误码 -11828）。自定义源已能成功返回播放 URL，失败发生在「直连 URL 播放」阶段。

用户选择方案 **A**：所有在线播放（含 128k/320k/flac 等）均先缓存到本地再播放，缓存保留 3 天。

## 目标

1. 解析出远程播放 URL 后，先下载到应用缓存目录，再以本地文件播放。
2. 缓存条目自创建起保留 **3 天**，过期自动删除。
3. 与用户主动「下载管理」分离：播放缓存是临时、自动的，不进入下载任务列表。

## 非目标

- 不修改自定义 JS 音源脚本协议与 `globalThis.lx` 宿主契约。
- 不把播放缓存展示为「已下载」或混入 `DownloadService` 任务列表。
- 不在本设计中处理输入法秒关（独立问题）。

## 架构

```
点播
  → urlResolver：MusicSourceService.getPlayUrlDetailed
  → PlaybackCacheService.getOrDownload(remoteUrl, cacheKey)
       命中且未过期 → file path / file:// URI
       未命中 → Dio 下载 → 写索引 → file path
  → LxAudioHandler 使用 AudioSource.uri(fileUri) 或等价本地源播放
```

### 组件

| 组件 | 职责 |
|------|------|
| `PlaybackCacheService`（新建） | 缓存目录、key、下载、索引、3 天过期与可选容量清理 |
| `main.dart` `urlResolver` | 解析成功后调用缓存，向播放器返回**本地路径/URI** |
| `LxAudioHandler` | 识别本地路径；播放本地文件；下载中保持 buffering |
| `DownloadService` | 不变：用户手动下载与播放缓存分离 |

## 缓存策略

### 目录

- 使用 `getApplicationSupportDirectory()/playback_cache/`（应用私有，不进用户「下载」语义）。

### Cache Key

- 输入：`platform`、`songId`（songmid/hash/id）、`quality`（requested 或 actual）、远程 URL 的 host+path（去掉 query 中易变 token 时优先用稳定字段）。
- 算法：`sha1(canonicalKeyString)` 十六进制。
- 目的：同曲不同音质不互相覆盖；URL 轮换时尽量仍能按 song+quality 命中（若仅用完整 URL 作 key，token 变化会导致重复下载——优先 `platform|songId|quality`，URL 仅作下载地址）。

**推荐 key：** `sha1("$platform|$songId|$quality")`  
**文件内容：** 该次解析得到的远程 URL 下载结果。  
若同一 key 下远程 URL 变更（CDN 换链），可覆盖写入并更新 `createdAt`。

### 文件命名

- `{key}.{ext}`
- `ext` 优先从 URL path 推断（`.mp3` / `.m4a` / `.flac` 等），否则从 `Content-Type`，默认 `.audio`。

### 索引

- 持久化：SharedPreferences JSON 列表或单文件 `playback_cache_index.json`。
- 字段：`key`, `path`, `remoteUrl`, `createdAt` (ms), `sizeBytes`, `quality`, `platform`, `songId`。

### TTL

- **3 天**（`createdAt + 72h`）。
- 清理时机：服务 `init`、每次 `getOrDownload` 前后惰性清理、可选定时。

### 容量（建议纳入实现）

- 软上限例如 **1GB**；超限按 `createdAt` 最旧删除直至低于上限。
- 若实现时间紧，可先只做 3 天 TTL，容量上限作为同 PR 或紧随其后的小项。

## 播放与并发

1. `urlResolver` 拿到 `PlayUrlResult` 后调用 `getOrDownload`。
2. 下载期间 `AudioHandler` 保持 `buffering`（已有逻辑可复用）。
3. 同一 `key` 并发请求应合并为单次下载（Completer 共享）。
4. 用户切歌：取消上一首未完成的下载 `CancelToken`（仅取消已无用的 key）。
5. 下载失败：记录日志；可 **一次** 回退直连远程 URL（非 FLAC 时更有意义）；仍失败则 `onError` 并按现有逻辑尝试下一首。

### iOS 与 FLAC

- 本地文件播放 FLAC 通常比网络流可靠；方案 A 下 FLAC 也走本地，不再依赖网络 FLAC 流。
- 若本地 FLAC 仍失败（设备解码限制），可再降质重新解析 320k 并缓存（可选增强，首版可不做）。

## 与现有下载功能的边界

| | 播放缓存 | 下载管理 |
|--|----------|----------|
| 触发 | 自动（播放） | 用户手动 |
| 目录 | `playback_cache/` | `downloads/` |
| 列表 UI | 无 | 有 |
| 生命周期 | 3 天 | 用户删除前保留 |

## 错误处理

- 磁盘满 / 写失败 → 日志 + 回退远程或失败提示。
- 远程 403/超时 → 不写残缺文件；删除临时 `.part`。
- 索引与文件不一致 → 以文件是否存在为准，清理脏索引。

## 测试要点

- Key 稳定：同 platform/songId/quality 二次播放命中缓存、不二次下载。
- 过期：伪造 `createdAt` 超过 3 天被清理。
- 并发：同 key 双请求只下载一次。
- `urlResolver` 返回路径可被 `AudioSource.uri` 以 `file://` 播放（或项目等价 API）。
- 与 `DownloadService` 任务列表互不污染。

## 实现落点（文件）

- 新建：`lib/core/audio/playback_cache_service.dart`（或 `lib/features/player/domain/`）
- 修改：`lib/main.dart`（urlResolver 接入缓存）
- 修改：`lib/core/audio/audio_handler.dart`（本地 URI、取消下载钩子如需要）
- 测试：`test/core/audio/playback_cache_service_test.dart`

## 成功标准

1. 点播任意音质均先出现本地缓存文件再开始稳定播放。
2. 3 天内再播同 key 不重新下载（可观察日志或 mock Dio）。
3. 超过 3 天的文件与索引被删除。
4. 用户「下载管理」行为与列表不受影响。
