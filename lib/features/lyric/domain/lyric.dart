class LyricLine {
  final Duration time;
  final String text;
  final String? translation;
  final List<LyricWord>? words;

  const LyricLine({
    required this.time,
    required this.text,
    this.translation,
    this.words,
  });

  bool get hasWordTiming => words != null && words!.isNotEmpty;
}

class LyricWord {
  final Duration time;
  final String text;
  /// 该字/词持续时间；无则按到下一字或行结束估算。
  final Duration? duration;

  const LyricWord({
    required this.time,
    required this.text,
    this.duration,
  });
}

class Lyrics {
  final String raw;
  final List<LyricLine> lines;

  const Lyrics({
    required this.raw,
    required this.lines,
  });

  factory Lyrics.empty() => const Lyrics(raw: '', lines: []);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  int getCurrentLineIndex(Duration position) {
    if (lines.isEmpty) return -1;
    // 尚未到首句
    if (position < lines.first.time) return -1;

    int low = 0;
    int high = lines.length - 1;
    int result = 0;

    while (low <= high) {
      final mid = (low + high) ~/ 2;
      if (lines[mid].time <= position) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    return result;
  }

  LyricLine? getCurrentLine(Duration position) {
    final index = getCurrentLineIndex(position);
    if (index >= 0 && index < lines.length) {
      return lines[index];
    }
    return null;
  }

  /// 当前行内已唱到的字索引；-1 表示尚未到该行或无字级时间。
  int getCurrentWordIndex(Duration position, int lineIndex) {
    if (lineIndex < 0 || lineIndex >= lines.length) return -1;
    final line = lines[lineIndex];
    final words = line.words;
    if (words == null || words.isEmpty) return -1;
    if (position < line.time) return -1;

    int active = -1;
    for (var i = 0; i < words.length; i++) {
      if (words[i].time <= position) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  /// 当前活动字的填充比例 0.0–1.0（KTV 流式）。
  double getWordFillProgress(Duration position, int lineIndex, int wordIndex) {
    if (lineIndex < 0 || lineIndex >= lines.length) return 0;
    final line = lines[lineIndex];
    final words = line.words;
    if (words == null || wordIndex < 0 || wordIndex >= words.length) return 0;

    final word = words[wordIndex];
    if (position <= word.time) return 0;

    Duration dur = word.duration ?? Duration.zero;
    if (dur <= Duration.zero) {
      if (wordIndex + 1 < words.length) {
        dur = words[wordIndex + 1].time - word.time;
      } else if (lineIndex + 1 < lines.length) {
        dur = lines[lineIndex + 1].time - word.time;
      } else {
        dur = const Duration(milliseconds: 400);
      }
    }
    if (dur <= Duration.zero) return 1;

    final elapsed = position - word.time;
    final p = elapsed.inMicroseconds / dur.inMicroseconds;
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    return p;
  }
}
