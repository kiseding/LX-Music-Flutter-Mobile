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
}

private func loadNowPlayingEntry(date: Date = Date()) -> LXNowPlayingEntry {
  let defaults = lxDefaults()
  let title = defaults?.string(forKey: "title") ?? "LX Music"
  let artist = defaults?.string(forKey: "artist") ?? "正在播放"
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

  func lxLiveActivityBackground() -> some View {
    activityBackgroundTint(Color.black.opacity(0.35))
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
      ProgressView(value: displayPositionMs, total: entry.durationMs)
        .tint(entry.isPlaying ? Color.accentColor : Color.white.opacity(0.35))
        .scaleEffect(x: 1, y: 0.6, anchor: .center)
    }
  }

  var body: some View {
    ZStack {
      Color(red: 0.07, green: 0.08, blue: 0.11)
      if family == .systemMedium {
        HStack(spacing: 14) {
          LXArtworkView(path: entry.artworkPath)
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
              .font(.headline)
              .foregroundStyle(.white)
              .lineLimit(2)
            Text(entry.artist)
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.72))
              .lineLimit(1)
            if !entry.album.isEmpty {
              Text(entry.album)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            }
            if !entry.lyric.isEmpty {
              Text(entry.lyric)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
            }
            Spacer(minLength: 0)
            progressBar
          }
        }
        .padding(16)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 11) {
            LXArtworkView(path: entry.artworkPath)
              .frame(width: 52, height: 52)
              .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
              Text(entry.artist)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            }
          }
          if entry.durationMs > 0 && !entry.album.isEmpty {
            Text(entry.album)
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.45))
              .lineLimit(1)
          }
          Spacer(minLength: 0)
          progressBar
        }
        .padding(14)
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
private struct LXLiveActivityContentView: View {
  let context: ActivityViewContext<LiveActivitiesAppAttributes>

  private var defaults: UserDefaults? {
    UserDefaults(suiteName: context.state.appGroupId ?? widgetGroupId)
  }

  private func value(_ key: String) -> String? {
    defaults?.string(forKey: context.attributes.prefixedKey(key))
  }

  private var title: String { context.state.title ?? (value("title") ?? "LX Music") }
  private var artist: String { context.state.artist ?? (value("artist") ?? "") }
  private var album: String { context.state.album ?? (value("album") ?? "") }
  private var artworkPath: String? { context.state.artworkPath ?? value("artworkPath") }
  private var isPlaying: Bool { context.state.isPlaying ?? (defaults?.bool(forKey: context.attributes.prefixedKey("playing")) ?? false) }
  private var positionMs: Double { context.state.positionMs ?? (defaults?.double(forKey: context.attributes.prefixedKey("positionMs")) ?? 0) }
  private var positionSyncedAtMs: Double { context.state.positionSyncedAtMs ?? (defaults?.double(forKey: context.attributes.prefixedKey("positionSyncedAtMs")) ?? 0) }
  private var durationMs: Double { context.state.durationMs ?? (defaults?.double(forKey: context.attributes.prefixedKey("durationMs")) ?? 0) }
  private var lyric: String { context.state.lyric ?? (value("lyric") ?? "") }

  private var currentPositionMs: Double {
    lxPlaybackPositionMs(
      positionMs: positionMs,
      durationMs: durationMs,
      syncedAtMs: positionSyncedAtMs,
      isPlaying: isPlaying
    )
  }

  private var progressRange: ClosedRange<Date>? {
    lxProgressRange(
      positionMs: positionMs,
      durationMs: durationMs,
      syncedAtMs: positionSyncedAtMs,
      isPlaying: isPlaying
    )
  }

  var body: some View {
    ZStack {
      Color(red: 0.07, green: 0.08, blue: 0.11)
      HStack(spacing: 12) {
        LXArtworkView(path: artworkPath)
          .frame(width: 48, height: 48)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
          Text(artist)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(1)
          if !album.isEmpty {
            Text(album)
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.45))
              .lineLimit(1)
          }
          if !lyric.isEmpty {
            Text(lyric)
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.78))
              .lineLimit(1)
          }
          if let range = progressRange {
            if isPlaying {
              ProgressView(timerInterval: range, countsDown: false)
                .tint(.white)
            } else {
              ProgressView(value: min(currentPositionMs, durationMs), total: durationMs)
                .tint(.white.opacity(0.6))
            }
          }
        }
        Spacer(minLength: 0)
        HStack(spacing: 18) {
          Link(destination: URL(string: "lxmusic://command/previous")!) {
            Image(systemName: "backward.fill").font(.title3)
          }
          Link(destination: URL(string: "lxmusic://command/toggle-play")!) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title2)
          }
          Link(destination: URL(string: "lxmusic://command/next")!) {
            Image(systemName: "forward.fill").font(.title3)
          }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
      }
      .padding(14)
    }
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
  let album = context.state.album ?? (value("album") ?? "")
  let artworkPath = context.state.artworkPath ?? value("artworkPath")
  let isPlaying = context.state.isPlaying ?? (defaults?.bool(forKey: context.attributes.prefixedKey("playing")) ?? false)
  let positionMs = context.state.positionMs ?? (defaults?.double(forKey: context.attributes.prefixedKey("positionMs")) ?? 0)
  let positionSyncedAtMs = context.state.positionSyncedAtMs ?? (defaults?.double(forKey: context.attributes.prefixedKey("positionSyncedAtMs")) ?? 0)
  let durationMs = context.state.durationMs ?? (defaults?.double(forKey: context.attributes.prefixedKey("durationMs")) ?? 0)
  let lyric = context.state.lyric ?? (value("lyric") ?? "")
  let currentPositionMs = lxPlaybackPositionMs(
    positionMs: positionMs,
    durationMs: durationMs,
    syncedAtMs: positionSyncedAtMs,
    isPlaying: isPlaying
  )
  let progressRange = lxProgressRange(
    positionMs: positionMs,
    durationMs: durationMs,
    syncedAtMs: positionSyncedAtMs,
    isPlaying: isPlaying
  )
  let remainingLabel = lxRemainingLabel(
    currentPositionMs: currentPositionMs,
    durationMs: durationMs
  )

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
        if !album.isEmpty {
          Text(album)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    DynamicIslandExpandedRegion(.trailing) {
      VStack(spacing: 2) {
        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
          .font(.title3)
        Text(remainingLabel)
          .font(.caption2)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
    DynamicIslandExpandedRegion(.bottom) {
      VStack(alignment: .leading, spacing: 4) {
        if !lyric.isEmpty {
          Text(lyric)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
        }
        if let range = progressRange {
          if isPlaying {
            ProgressView(timerInterval: range, countsDown: false)
          } else {
            ProgressView(value: min(currentPositionMs, durationMs), total: durationMs)
          }
        }
        HStack {
          Spacer()
          Link(destination: URL(string: "lxmusic://command/previous")!) {
            Image(systemName: "backward.fill").font(.subheadline)
          }
          Spacer()
          Link(destination: URL(string: "lxmusic://command/toggle-play")!) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title3)
          }
          Spacer()
          Link(destination: URL(string: "lxmusic://command/next")!) {
            Image(systemName: "forward.fill").font(.subheadline)
          }
          Spacer()
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 8)
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

private func lxRemainingLabel(currentPositionMs: Double, durationMs: Double) -> String {
  let remaining = max(0, (durationMs - currentPositionMs) / 1000)
  let minutes = Int(remaining) / 60
  let seconds = Int(remaining) % 60
  return String(format: "%d:%02d", minutes, seconds)
}

@available(iOSApplicationExtension 16.1, *)
struct LXMusicLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
      LXLiveActivityContentView(context: context)
        .lxLiveActivityBackground()
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
