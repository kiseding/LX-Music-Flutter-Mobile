# LX Source Host Compatibility Design

## Goal

Make the iOS application execute imported LX Music source scripts through an iOS JavaScriptCore host that matches the public LX Desktop `globalThis.lx` contract. The app must use the script's own dynamic API selection, signing, configuration, and response logic rather than converting scripts to Dart API templates.

## Scope

- Target iOS JavaScriptCore in the first release.
- Support the complete documented LX host surface used by custom sources: events, HTTP requests, script metadata, crypto, buffers, zlib, initialization, update notifications, `musicUrl`, lyric, and picture actions.
- Preserve source isolation: one runtime per source and no shared source state.
- Preserve full source text. Import only parses metadata for display.
- Validate using the existing Huibq source and the obfuscated Flower source as representative sources.

## Non-goals

- Do not extract, rewrite, or persist `API_URL`, API keys, request templates, or script internals.
- Do not restore the removed built-in third-party parsing APIs.
- Do not promise Android, desktop, or web protocol parity in this release.

## Host Contract

The injected `globalThis.lx` matches LX Desktop's observable behavior:

- `EVENT_NAMES`: `request`, `inited`, and `updateAlert`.
- `on('request', handler)`: stores one handler and returns a resolved Promise. A later handler replaces the earlier one.
- `send('inited', data)`: returns a Promise, validates declared source capabilities, and completes runtime initialization.
- `send('updateAlert', data)`: returns a Promise and forwards one sanitized update event.
- `request(url, options, callback)`: returns a cancellation function and invokes exactly once as `(error, response, body)`.
- `response` contains `statusCode`, `statusMessage`, lowercase headers, byte count, raw response bytes, and parsed-or-raw `body`.
- `utils.crypto`: `md5`, `aesEncrypt`, `rsaEncrypt`, and `randomBytes` operate on binary values compatible with source scripts.
- `utils.buffer`: `from` and `bufToString` operate on compatible binary wrappers.
- `utils.zlib`: `inflate` and `deflate` return JavaScript Promises.
- `currentScriptInfo`: carries the source metadata and full `rawScript`.
- `version` is `2.0.0`; `env` is `desktop`, matching the official source host.

## Components

### Source Runtime

`CustomSourceEngine` becomes a small facade over a runtime session. A session owns the JavaScriptCore instance, injected host API, source metadata, one request handler, initialization state, pending HTTP cancellations, and event stream.

Loading executes the exact script text in the isolated session. Script exceptions, trusted asynchronous errors, and unhandled rejections become source error events and cause initialization failure until the script explicitly completes `inited`.

### HTTP Bridge

The bridge receives the source-computed request URL and options. It supports `method`, `timeout`, `headers`, `body`, `form`, and `formData`; enforces a 60-second maximum; preserves binary response data; parses JSON when possible; and returns the official response shape. Cancellation aborts the corresponding Dio request.

### Binary Bridge

Binary arguments cross the Dart/JavaScript boundary as a JSON-safe Buffer wrapper with explicit byte/base64 representations. The host exposes the operations sources need instead of relying on JavaScript string coercion. The crypto and zlib bridges resolve or reject Promises consistently.

### Capability Validation

`inited.sources` is accepted only for known LX platforms and allowed actions. Declared qualities are intersected with supported qualities. Playback, lyric, and picture requests are sent only when the selected source declared support for that action.

### Error and Observability Model

Every boundary emits a structured event containing action, source ID, request URL, HTTP status, sanitized response summary, or script error. Secret values and authorization header values are never emitted. `getMusicUrl`, lyric, and picture operations preserve the error long enough for the custom-source log view and the player UI to explain the failure.

## Data Flow

1. Import stores the original script and parsed display metadata.
2. Enabling/loading creates a source-specific JSC session and injects `globalThis.lx`.
3. Script registers one request handler and calls `send(inited, sources)`.
4. The app validates capabilities and exposes the compatible platform/action set.
5. Playback dispatches `{ source, action: 'musicUrl', info: { type, musicInfo } }` to the registered handler.
6. The script computes its own API URL, headers, tokens, song ID mapping, and request body.
7. `lx.request` uses the Dart bridge and returns official `(error, response, body)` arguments.
8. Script resolves a final HTTP(S) URL; the app validates it before handing it to the player.

## Acceptance

- Huibq source initializes and its computed request includes its script-defined URL and `X-Request-Key`.
- Flower source initializes, completes its remote config flow, computes its platform-specific URL/header set, and returns a valid `body.data` URL when the upstream service is available.
- Source update notifications are surfaced once.
- Malformed, unsupported, rejected, timed-out, and canceled requests report useful errors without leaking secrets.
- Existing custom source persistence and user-import workflows continue to work.
- A GitHub Actions iOS IPA is built from the final pushed commit.
