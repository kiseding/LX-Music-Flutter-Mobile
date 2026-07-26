# Playback Local Cache Implementation Plan

> **For agentic workers:** Implement task-by-task with TDD. Steps use checkbox syntax.

**Goal:** All online playback downloads to local cache first, then plays from file; cache TTL 3 days.

**Architecture:** `PlaybackCacheService` owns disk cache + index; `urlResolver` returns local `file://` path after resolve+download; `LxAudioHandler` plays local URIs.

**Tech Stack:** Flutter, Dio, path_provider, crypto, just_audio, SharedPreferences via StorageService.

## Global Constraints

- Separate from user DownloadService (`downloads/` vs `playback_cache/`)
- Key: `sha1(platform|songId|quality)`
- TTL: 3 days
- Soft cap: 1GB, oldest first

---

### Task 1: PlaybackCacheService + tests

**Files:**
- Create: `lib/core/audio/playback_cache_service.dart`
- Create: `test/core/audio/playback_cache_service_test.dart`

### Task 2: Wire urlResolver

**Files:**
- Modify: `lib/main.dart`

### Task 3: AudioHandler local file playback

**Files:**
- Modify: `lib/core/audio/audio_handler.dart`
