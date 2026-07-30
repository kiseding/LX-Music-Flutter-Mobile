import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/app.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  testWidgets('root messenger consumes one playback message exactly once',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          home: const PlayerMessageListener(
            child: Scaffold(body: SizedBox.expand()),
          ),
        ),
      ),
    );

    container.read(playerMessageProvider.notifier).state = '播放失败';
    await tester.pump();

    expect(find.text('播放失败'), findsOneWidget);
    expect(container.read(playerMessageProvider), isNull);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('播放失败'), findsNothing);
  });

  testWidgets('message remains pending until a messenger exists',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(playerMessageProvider.notifier).state = '稍后显示';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const PlayerMessageListener(child: SizedBox()),
      ),
    );
    await tester.pump();

    expect(container.read(playerMessageProvider), '稍后显示');
  });
}
