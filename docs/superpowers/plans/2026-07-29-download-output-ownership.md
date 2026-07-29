# Download Output Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent delayed Wi-Fi policy checks and stale download attempts from starting, deleting, or promoting output owned by a newer attempt or re-added task.

**Architecture:** `DownloadService` uses a monotonically increasing connectivity epoch to invalidate pre-loss asynchronous Wi-Fi answers before they reserve a slot. Each physical download owns an immutable final destination derived from its task ID and attempt revision; promotion and cleanup validate attempt authority at every asynchronous boundary and only touch that attempt's files.

**Tech Stack:** Flutter/Dart, Dio cancellation, `dart:io`, `flutter_test`.

## Global Constraints

- Final physical output is exactly `<taskId>-<attemptRevision><extension>`.
- `DownloadTask.savePath` stores the exact immutable final output path.
- Existing attempt revisions remain persisted and active reservations remain held until executor finalization.
- Cleanup may only remove paths owned by the exact task attempt.
- Tests follow RED, then minimal GREEN, before each behavior change.

---

### Task 1: Reject Stale Wi-Fi Answers

**Files:**
- Modify: `test/features/download/domain/download_service_test.dart`
- Modify: `lib/features/download/domain/download_service.dart`

**Interfaces:**
- Produces: `_connectivityEpoch` and a Wi-Fi callback that validates the captured epoch before `_processQueueAllowed()` reserves slots.

- [ ] **Step 1: Write the failing test**

```dart
test('delayed Wi-Fi answer after mobile event cannot reserve a slot', () async {
  final answer = Completer<DownloadNetwork>();
  final network = StreamController<DownloadNetwork>.broadcast();
  final downloader = _GatedDownloader();
  final service = DownloadService(
    wifiOnly: true,
    currentNetwork: () => answer.future,
    connectivity: network.stream,
    downloader: downloader.call,
    storage: _MemoryStorage(),
    taskIdFactory: () => 'epoch-id',
  );
  await service.addTask(_song('a'));
  network.add(DownloadNetwork.mobile);
  await Future<void>.delayed(Duration.zero);
  answer.complete(DownloadNetwork.wifi);
  await Future<void>.delayed(Duration.zero);
  expect(downloader.started, isEmpty);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/download/domain/download_service_test.dart --plain-name 'delayed Wi-Fi answer after mobile event cannot reserve a slot'`

Expected: FAIL because the delayed Wi-Fi answer starts the task.

- [ ] **Step 3: Write minimal implementation**

```dart
int _connectivityEpoch = 0;

void _processQueue() {
  if (_disposed) return;
  if (_wifiOnly) {
    final epoch = _connectivityEpoch;
    _currentNetwork().then((network) {
      if (!_disposed && _wifiOnly && epoch == _connectivityEpoch &&
          network == DownloadNetwork.wifi) {
        _processQueueAllowed();
      }
    });
    return;
  }
  _processQueueAllowed();
}

void _onNetworkChanged(DownloadNetwork network) {
  if (!_wifiOnly) return;
  if (network == DownloadNetwork.wifi) {
    _processQueue();
    return;
  }
  _connectivityEpoch++;
  // Existing cancellation loop remains unchanged.
}
```

- [ ] **Step 4: Run focused test to verify it passes**

Run: `flutter test test/features/download/domain/download_service_test.dart --plain-name 'delayed Wi-Fi answer after mobile event cannot reserve a slot'`

Expected: PASS.

### Task 2: Make Physical Output Attempt-Owned

**Files:**
- Modify: `test/features/download/domain/download_task_test.dart`
- Modify: `lib/features/download/domain/download_service.dart`

**Interfaces:**
- Produces: attempt-owned final path helper and guarded promotion/cleanup.

- [ ] **Step 1: Write failing filesystem race tests**

```dart
test('attempt final path is task and revision owned', () {
  expect(DownloadService.completedPathName('task/a', 3, '.mp3'),
      'task_a-3.mp3');
});
```

Add gated physical-download tests that retry or delete and re-add the same music ID while old work ignores cancellation. Complete the old work after the new attempt has written its distinct final file; assert the new task's `savePath` and file bytes remain unchanged.

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/features/download/domain/download_task_test.dart test/features/download/domain/download_service_test.dart`

Expected: FAIL because production output derives from `musicId` and stale cleanup is music-ID-wide.

- [ ] **Step 3: Write minimal implementation**

```dart
String _finalPathFor(String taskId, int revision, String extension) =>
    '$_downloadDir/${safeDownloadBaseName(taskId)}-$revision$extension';

Future<bool> _promoteOwnedPart(
    File part, String savePath, _DownloadAttempt attempt) async {
  if (!_isCurrent(attempt)) return false;
  await part.rename(savePath);
  return _isCurrent(attempt);
}
```

Use `_finalPathFor` instead of the music-ID basename. Remove sibling cleanup. Guard all awaited validation, deletion, promotion, and size reads with attempt currency. `_safeDeleteOwned` accepts only a path constructed for that attempt and returns without deletion when stale. Task-level delete/cancel removes only its persisted `savePath`.

- [ ] **Step 4: Run focused suites to verify they pass**

Run: `flutter test test/features/download/domain/download_task_test.dart test/features/download/domain/download_service_test.dart`

Expected: PASS.

### Task 3: Report And Verify

**Files:**
- Modify: `.superpowers/sdd/network-task-4-report.md`

- [ ] **Step 1: Record implementation and exact test evidence**

Document the connectivity epoch, immutable output ownership, stale-race coverage, analysis outcome, and remaining limitations.

- [ ] **Step 2: Run verification**

Run: `flutter test test/features/download/domain/download_task_test.dart test/features/download/domain/download_service_test.dart && flutter test && flutter analyze && git diff --check`

Expected: focused and full tests pass; analyzer results are recorded exactly; diff check is clean.

- [ ] **Step 3: Commit implementation**

```bash
git -c user.name='kiseding' -c user.email='236300865+kiseding@users.noreply.github.com' \
  commit -m "fix: isolate download attempt outputs"
```
