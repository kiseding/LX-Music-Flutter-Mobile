import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';

void main() {
  group('nextQueueIndex', () {
    test('sequential advances and stops at end without loop', () {
      expect(
        nextQueueIndex(
          currentIndex: 0,
          queueLength: 3,
          shuffle: false,
          loop: false,
        ),
        1,
      );
      expect(
        nextQueueIndex(
          currentIndex: 2,
          queueLength: 3,
          shuffle: false,
          loop: false,
        ),
        -1,
      );
    });

    test('sequential loops to start when enabled', () {
      expect(
        nextQueueIndex(
          currentIndex: 2,
          queueLength: 3,
          shuffle: false,
          loop: true,
        ),
        0,
      );
    });

    test('shuffle picks a different index when possible', () {
      var calls = 0;
      final idx = nextQueueIndex(
        currentIndex: 1,
        queueLength: 4,
        shuffle: true,
        loop: true,
        randomNext: (max) {
          calls++;
          expect(max, 3); // length-1 candidates
          return 2; // maps to real index 3 after skipping current
        },
      );
      expect(calls, 1);
      expect(idx, 3);
      expect(idx, isNot(1));
    });

    test('shuffle with single item stays on it', () {
      expect(
        nextQueueIndex(
          currentIndex: 0,
          queueLength: 1,
          shuffle: true,
          loop: false,
        ),
        0,
      );
    });
  });

  group('previousQueueIndex', () {
    test('sequential goes back and wraps with loop', () {
      expect(
        previousQueueIndex(
          currentIndex: 2,
          queueLength: 3,
          shuffle: false,
          loop: false,
        ),
        1,
      );
      expect(
        previousQueueIndex(
          currentIndex: 0,
          queueLength: 3,
          shuffle: false,
          loop: true,
        ),
        2,
      );
    });
  });

  group('completionQueueIndex', () {
    test('repeat one completion keeps the current queue item', () {
      expect(
        completionQueueIndex(
          currentIndex: 1,
          queueLength: 3,
          repeatMode: AudioServiceRepeatMode.one,
          shuffle: false,
        ),
        1,
      );
    });

    test('repeat all wraps while no-repeat stops', () {
      expect(
        completionQueueIndex(
          currentIndex: 2,
          queueLength: 3,
          repeatMode: AudioServiceRepeatMode.all,
          shuffle: false,
        ),
        0,
      );
      expect(
        completionQueueIndex(
          currentIndex: 2,
          queueLength: 3,
          repeatMode: AudioServiceRepeatMode.none,
          shuffle: false,
        ),
        -1,
      );
    });

    test('repeat group wraps to the first queue item', () {
      expect(
        completionQueueIndex(
          currentIndex: 2,
          queueLength: 3,
          repeatMode: AudioServiceRepeatMode.group,
          shuffle: false,
        ),
        0,
      );
    });

    test('shuffle completion uses the supplied selection', () {
      var calls = 0;
      expect(
        completionQueueIndex(
          currentIndex: 1,
          queueLength: 4,
          repeatMode: AudioServiceRepeatMode.none,
          shuffle: true,
          randomNext: (max) {
            calls++;
            expect(max, 3);
            return 1;
          },
        ),
        2,
      );
      expect(calls, 1);
    });

    test('single-item no-repeat completion stops', () {
      expect(
        completionQueueIndex(
          currentIndex: 0,
          queueLength: 1,
          repeatMode: AudioServiceRepeatMode.none,
          shuffle: false,
        ),
        -1,
      );
    });
  });
}
