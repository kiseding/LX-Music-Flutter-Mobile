# Download reliability + word-timed KTV lyrics

Date: 2026-07-26  
Status: approved

## Goals

1. Make user downloads reliable end-to-end (resolve URL → HTTP → validate → permanent file).
2. When source lyrics include word timing, render KTV-style progressive highlight; otherwise keep line highlight.

## Non-goals

- Merge user downloads with 3-day playback cache.
- Invent word timings for plain LRC.
- Redesign download UI.

## Observed failures

- 告白气球 → `无法获取下载链接`: retry/queue path drops `MusicItem`, cannot re-resolve URL.
- 七里香 → `DioException [unknown]: null`: bare Dio without headers/timeouts/validation; may hit bad/expired URLs.

## Approach A (chosen)

Reuse proven playback download patterns inside `DownloadService`, keep permanent downloads separate from `PlaybackCacheService`.

### Download

1. Reconstruct `MusicItem` from task metadata on every start/retry/resume.
2. Resolve via `getPlayUrlDetailed` + `qualityChain`; require `isPlayableMediaUrl`.
3. Dio: timeouts, iOS-friendly UA/Referer, http→https for QQ CDN, `CancelToken` per task.
4. Write `*.part`, reject empty/tiny/non-audio bodies, detect extension via magic bytes, rename to final path.
5. Pause/cancel abort in-flight request; clear partial files.
6. Persist tasks; on init, demote stuck `downloading` → `pending` and drain queue.

### Lyrics

1. Extend `LyricWord` with optional `duration`.
2. Parse LRCX `<startMs,durationMs>text` and QRC absolute word tags into `words`.
3. `LyricService` routes timed-word payloads to word parsers (do not strip tags).
4. `LyricView` KTV fill on current line from player position; plain lines stay whole-line highlight.

### Tests

- LRCX/QRC parser samples.
- Download helpers: music rebuild, quality chain resolve mock path, extension detection reuse.
- Existing suite still green.

## Out of scope follow-ups

- Wi-Fi-only download setting enforcement.
- Background download isolates.
