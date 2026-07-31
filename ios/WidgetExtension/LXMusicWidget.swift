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
  let artworkPath: String?
  let isPlaying: Bool
  let positionMs: Double
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
  return LXNowPlayingEntry(
    date: date,
    title: title,
    artist: artist,
    album: album,
    artworkPath: artworkPath,
    isPlaying: isPlaying,
    positionMs: positionMs,
    durationMs: durationMs
  )
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

private struct LXNowPlayingWidgetView: View {
  let entry: LXNowPlayingEntry

  var body: some View {
    ZStack {
      Color(red: 0.07, green: 0.08, blue: 0.11)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          LXArtworkView(path: entry.artworkPath)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
              .font(.headline)
              .foregroundStyle(.white)
              .lineLimit(2)
            Text(entry.artist)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.72))
              .lineLimit(1)
            if !entry.album.isEmpty {
              Text(entry.album)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            }
          }
        }
        if entry.durationMs > 0 {
          ProgressView(value: min(entry.positionMs, entry.durationMs), total: entry.durationMs)
            .tint(entry.isPlaying ? Color.accentColor : Color.white.opacity(0.35))
            .scaleEffect(x: 1, y: 0.6, anchor: .center)
        }
      }
      .padding(14)
    }
    .widgetURL(URL(string: "lxmusic://nowplaying"))
  }
}

struct LXMusicHomeWidget: Widget {
  let kind = "LXMusicHomeWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: LXNowPlayingProvider()) { entry in
      LXNowPlayingWidgetView(entry: entry)
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

    init(appGroupId: String? = nil) {
      self.appGroupId = appGroupId
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
      appGroupId = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys("appGroupId"))
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

  private var title: String { value("title") ?? "LX Music" }
  private var artist: String { value("artist") ?? "" }
  private var artworkPath: String? { value("artworkPath") }
  private var isPlaying: Bool { defaults?.bool(forKey: context.attributes.prefixedKey("playing")) ?? false }
  private var positionMs: Double { defaults?.double(forKey: context.attributes.prefixedKey("positionMs")) ?? 0 }
  private var durationMs: Double { defaults?.double(forKey: context.attributes.prefixedKey("durationMs")) ?? 0 }

  private var progressRange: ClosedRange<Date> {
    let now = Date()
    let position = max(0, positionMs / 1000)
    let duration = max(position + 60, durationMs / 1000)
    let start = now.addingTimeInterval(-position)
    return start...(start.addingTimeInterval(duration))
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
          if durationMs > 0 {
            ProgressView(timerInterval: progressRange, countsDown: false)
              .tint(.white)
          }
        }
        Spacer(minLength: 0)
        Image(systemName: isPlaying ? "play.fill" : "pause.fill")
          .font(.title3)
          .foregroundStyle(.white)
      }
      .padding(14)
    }
    .activityBackgroundTint(Color.black.opacity(0.35))
  }
}

@available(iOSApplicationExtension 16.1, *)
private struct LXLiveActivityDynamicIsland: View {
  let context: ActivityViewContext<LiveActivitiesAppAttributes>

  private var defaults: UserDefaults? {
    UserDefaults(suiteName: context.state.appGroupId ?? widgetGroupId)
  }

  private func value(_ key: String) -> String? {
    defaults?.string(forKey: context.attributes.prefixedKey(key))
  }

  private var title: String { value("title") ?? "LX Music" }
  private var artist: String { value("artist") ?? "" }
  private var artworkPath: String? { value("artworkPath") }
  private var isPlaying: Bool { defaults?.bool(forKey: context.attributes.prefixedKey("playing")) ?? false }
  private var positionMs: Double { defaults?.double(forKey: context.attributes.prefixedKey("positionMs")) ?? 0 }
  private var durationMs: Double { defaults?.double(forKey: context.attributes.prefixedKey("durationMs")) ?? 0 }

  private var progressRange: ClosedRange<Date> {
    let now = Date()
    let position = max(0, positionMs / 1000)
    let duration = max(position + 60, durationMs / 1000)
    let start = now.addingTimeInterval(-position)
    return start...(start.addingTimeInterval(duration))
  }

  var body: some View {
    DynamicIsland {
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
        Image(systemName: isPlaying ? "play.fill" : "pause.fill")
          .font(.title3)
      }
      DynamicIslandExpandedRegion(.bottom) {
        if durationMs > 0 {
          ProgressView(timerInterval: progressRange, countsDown: false)
            .padding(.horizontal, 8)
        }
      }
    } compactLeading: {
      LXArtworkView(path: artworkPath)
        .frame(width: 24, height: 24)
        .clipShape(Circle())
    } compactTrailing: {
      Image(systemName: isPlaying ? "play.fill" : "pause.fill")
        .font(.footnote)
    } minimal: {
      LXArtworkView(path: artworkPath)
        .frame(width: 24, height: 24)
        .clipShape(Circle())
    }
  }
}

@available(iOSApplicationExtension 16.1, *)
struct LXMusicLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
      LXLiveActivityContentView(context: context)
    } dynamicIsland: { context in
      LXLiveActivityDynamicIsland(context: context)
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
