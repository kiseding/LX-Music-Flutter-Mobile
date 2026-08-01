import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

private let widgetGroupId = "group.com.lxmusic.lxMusicFlutter"

private func lxDefaults() -> UserDefaults? {
  UserDefaults(suiteName: widgetGroupId)
}

private struct LXNowPlayingEntry: TimelineEntry {
  let date: Date
  let title: String
  let artist: String
  let album: String
  let lyric: String
  let artworkPath: String?
  let isPlaying: Bool
  let positionMs: Double
  let positionSyncedAtMs: Double
  let durationMs: Double

  var hasNowPlayingData: Bool {
    !title.isEmpty || !artist.isEmpty
  }
}

private func loadNowPlayingEntry(date: Date = Date()) -> LXNowPlayingEntry {
  let defaults = lxDefaults()
  let title = defaults?.string(forKey: "title") ?? ""
  let artist = defaults?.string(forKey: "artist") ?? ""
  let album = defaults?.string(forKey: "album") ?? ""
  let artworkPath = defaults?.string(forKey: "artworkPath")
  let isPlaying = defaults?.bool(forKey: "playing") ?? false
  let positionMs = defaults?.double(forKey: "positionMs") ?? 0
  let durationMs = defaults?.double(forKey: "durationMs") ?? 0
  let positionSyncedAtMs = defaults?.double(forKey: "positionSyncedAtMs") ?? 0
  let lyric = defaults?.string(forKey: "lyric") ?? ""
  return LXNowPlayingEntry(
    date: date,
    title: title,
    artist: artist,
    album: album,
    lyric: lyric,
    artworkPath: artworkPath,
    isPlaying: isPlaying,
    positionMs: positionMs,
    positionSyncedAtMs: positionSyncedAtMs,
    durationMs: durationMs
  )
}

private func lxPlaybackPositionMs(
  positionMs: Double,
  durationMs: Double,
  syncedAtMs: Double,
  isPlaying: Bool,
  now: Date = Date()
) -> Double {
  guard isPlaying, syncedAtMs > 0 else { return positionMs }
  let elapsedMs = max(0, now.timeIntervalSince1970 * 1000 - syncedAtMs)
  let duration = max(positionMs, durationMs)
  return min(max(0, positionMs + elapsedMs), max(duration, 1))
}

private func lxProgressRange(
  positionMs: Double,
  durationMs: Double,
  syncedAtMs: Double,
  isPlaying: Bool,
  now: Date = Date()
) -> ClosedRange<Date>? {
  guard durationMs > 0 else { return nil }
  let currentPositionMs = lxPlaybackPositionMs(
    positionMs: positionMs,
    durationMs: durationMs,
    syncedAtMs: syncedAtMs,
    isPlaying: isPlaying,
    now: now
  )
  let position = max(0, currentPositionMs / 1000)
  let duration = max(position + 1, durationMs / 1000)
  let start = now.addingTimeInterval(-position)
  return start...(start.addingTimeInterval(duration))
}

private struct LXNowPlayingProvider: TimelineProvider {
  func placeholder(in context: Context) -> LXNowPlayingEntry {
    loadNowPlayingEntry()
  }

  func getSnapshot(in context: Context, completion: @escaping (LXNowPlayingEntry) -> Void) {
    completion(loadNowPlayingEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<LXNowPlayingEntry>) -> Void) {
    let entry = loadNowPlayingEntry()
    let refresh = entry.isPlaying
      ? Date().addingTimeInterval(30)
      : Date().addingTimeInterval(300)
    completion(Timeline(entries: [entry], policy: .after(refresh)))
  }
}

private struct LXArtworkView: View {
  let path: String?

  var body: some View {
    if let path, let image = UIImage(contentsOfFile: path) {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
    } else {
      ZStack {
        LinearGradient(
          colors: [Color(red: 0.16, green: 0.20, blue: 0.35), Color(red: 0.10, green: 0.10, blue: 0.16)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        Image(systemName: "music.note")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.white.opacity(0.65))
      }
    }
  }
}

private struct LXWidgetArtwork: View {
  let path: String?
  let size: CGFloat

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      LXArtworkView(path: path)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
      Circle()
        .fill(Color(red: 0.07, green: 0.08, blue: 0.11))
        .frame(width: size * 0.29, height: size * 0.29)
        .overlay {
          Image(systemName: "waveform")
            .font(.system(size: size * 0.12, weight: .bold))
            .foregroundStyle(Color.accentColor)
        }
        .offset(x: size * 0.07, y: size * 0.07)
    }
  }
}

private extension View {
  @ViewBuilder
  func lxWidgetBackground() -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(for: .widget) {
        Color(red: 0.07, green: 0.08, blue: 0.11)
      }
    } else {
      self
    }
  }
}

private struct LXNowPlayingWidgetView: View {
  let entry: LXNowPlayingEntry

  @Environment(\.widgetFamily) private var family

  private var displayPositionMs: Double {
    min(
      lxPlaybackPositionMs(
        positionMs: entry.positionMs,
        durationMs: entry.durationMs,
        syncedAtMs: entry.positionSyncedAtMs,
        isPlaying: entry.isPlaying
      ),
      entry.durationMs
    )
  }

  @ViewBuilder
  private var progressBar: some View {
    if entry.durationMs > 0 {
      // 播放中用绝对时间区间让系统平滑推进进度，避免 30s 刷新时跳变。
      let range = lxProgressRange(
        positionMs: entry.positionMs,
        durationMs: entry.durationMs,
        syncedAtMs: entry.positionSyncedAtMs,
        isPlaying: entry.isPlaying,
        now: entry.date
      )
      if let range, entry.isPlaying {
        ProgressView(timerInterval: range, countsDown: false)
          .tint(Color.accentColor)
          .scaleEffect(x: 1, y: 0.6, anchor: .center)
      } else {
        ProgressView(value: displayPositionMs, total: entry.durationMs)
          .tint(entry.isPlaying ? Color.accentColor : Color.white.opacity(0.35))
          .scaleEffect(x: 1, y: 0.6, anchor: .center)
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "music.note.list")
          .foregroundStyle(Color.accentColor)
        Text("LX Music")
          .font(.headline.weight(.semibold))
          .foregroundStyle(.white)
      }
      Spacer(minLength: 0)
      Text("打开 LX Music 开始播放")
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.62))
      HStack(spacing: 5) {
        Circle()
          .fill(Color.accentColor)
          .frame(width: 5, height: 5)
        Text("正在等待播放内容")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.42))
      }
    }
    .padding(16)
  }

  private var smallNowPlaying: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        LXWidgetArtwork(path: entry.artworkPath, size: 58)
        VStack(alignment: .leading, spacing: 3) {
          Text(entry.title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(2)
          Text(entry.artist)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.68))
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      HStack(spacing: 7) {
        Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
          .font(.caption.weight(.bold))
          .foregroundStyle(entry.isPlaying ? Color.accentColor : .white.opacity(0.55))
        Text(entry.isPlaying ? "正在播放" : "已暂停")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.58))
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white.opacity(0.4))
      }
      progressBar
    }
    .padding(16)
  }

  private var mediumNowPlaying: some View {
    HStack(spacing: 16) {
      LXWidgetArtwork(path: entry.artworkPath, size: 104)
      VStack(alignment: .leading, spacing: 5) {
        Text("正在播放")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.accentColor)
        Text(entry.title)
          .font(.headline.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(2)
        Text(entry.artist)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.68))
          .lineLimit(1)
        if !entry.album.isEmpty {
          Text(entry.album)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.42))
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        HStack(spacing: 8) {
          Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(entry.isPlaying ? Color.accentColor : .white.opacity(0.55))
          Text(entry.isPlaying ? "正在播放" : "已暂停")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.58))
        }
        progressBar
      }
    }
    .padding(16)
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.10, green: 0.12, blue: 0.18),
          Color(red: 0.04, green: 0.05, blue: 0.08),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      if !entry.hasNowPlayingData {
        emptyState
      } else if family == .systemMedium {
        mediumNowPlaying
      } else {
        smallNowPlaying
      }
    }
    .widgetURL(URL(string: "lxmusic://nowplaying"))
  }
}

struct LXMusicHomeWidget: Widget {
  let kind = "LXMusicHomeWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: LXNowPlayingProvider()) { entry in
      LXNowPlayingWidgetView(entry: entry)
        .lxWidgetBackground()
    }
    .configurationDisplayName("正在播放")
    .description("LX Music 当前播放的歌曲")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
  public typealias LiveDeliveryData = ContentState

  public struct ContentState: Codable, Hashable {
    var appGroupId: String?
    var title: String?
    var artist: String?
    var album: String?
    var artworkPath: String?
    var isPlaying: Bool?
    var positionMs: Double?
    var positionSyncedAtMs: Double?
    var durationMs: Double?
    var lyric: String?

    init(appGroupId: String? = nil, data: [String: Any]? = nil) {
      self.appGroupId = appGroupId
      self.title = Self.raw(data, "title") as? String
      self.artist = Self.raw(data, "artist") as? String
      self.album = Self.raw(data, "album") as? String
      self.artworkPath = Self.raw(data, "artworkPath") as? String
      self.isPlaying = Self.raw(data, "playing") as? Bool
      self.positionMs = Self.raw(data, "positionMs") as? Double
      self.positionSyncedAtMs = Self.raw(data, "positionSyncedAtMs") as? Double
      self.durationMs = Self.raw(data, "durationMs") as? Double
      self.lyric = Self.raw(data, "lyric") as? String
    }

    private static func raw(_ data: [String: Any]?, _ key: String) -> Any? {
      guard let value = data?[key] else { return nil }
      return value
    }
  }

  var id: UUID

  init(id: UUID = UUID()) {
    self.id = id
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: DynamicCodingKeys("id")) ?? UUID()
  }
}

private struct DynamicCodingKeys: CodingKey {
  var stringValue: String
  var intValue: Int?

  init(_ stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    return nil
  }
}

extension LiveActivitiesAppAttributes {
  func prefixedKey(_ key: String) -> String {
    "\(id)_\(key)"
  }
}

@available(iOSApplicationExtension 16.1, *)
private func lxDynamicIsland(context: ActivityViewContext<LiveActivitiesAppAttributes>) -> DynamicIsland {
  let defaults = UserDefaults(suiteName: context.state.appGroupId ?? widgetGroupId)

  func value(_ key: String) -> String? {
    defaults?.string(forKey: context.attributes.prefixedKey(key))
  }

  let title = context.state.title ?? (value("title") ?? "LX Music")
  let artist = context.state.artist ?? (value("artist") ?? "")
  let artworkPath = context.state.artworkPath ?? value("artworkPath")
  let isPlaying = context.state.isPlaying ?? (defaults?.bool(forKey: context.attributes.prefixedKey("playing")) ?? false)
  let positionMs = context.state.positionMs ?? (defaults?.double(forKey: context.attributes.prefixedKey("positionMs")) ?? 0)
  let positionSyncedAtMs = context.state.positionSyncedAtMs ?? (defaults?.double(forKey: context.attributes.prefixedKey("positionSyncedAtMs")) ?? 0)
  let durationMs = context.state.durationMs ?? (defaults?.double(forKey: context.attributes.prefixedKey("durationMs")) ?? 0)
  return DynamicIsland {
    DynamicIslandExpandedRegion(.leading) {
      LXArtworkView(path: artworkPath)
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    DynamicIslandExpandedRegion(.center) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
        Text(artist)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    DynamicIslandExpandedRegion(.trailing) {
      Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        .font(.title3)
    }
  } compactLeading: {
    LXArtworkView(path: artworkPath)
      .frame(width: 24, height: 24)
      .clipShape(Circle())
  } compactTrailing: {
    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
      .font(.footnote)
  } minimal: {
    LXArtworkView(path: artworkPath)
      .frame(width: 24, height: 24)
      .clipShape(Circle())
  }
}

@available(iOSApplicationExtension 16.1, *)
struct LXMusicLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { _ in
      // Keep the Live Activity available to Dynamic Island, but render no
      // separate lock-screen card.
      EmptyView()
    } dynamicIsland: { context in
      lxDynamicIsland(context: context)
    }
  }
}

@main
struct LXMusicWidgets: WidgetBundle {
  var body: some Widget {
    LXMusicHomeWidget()
    LXMusicLiveActivity()
  }
}
