import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/app.dart';
import 'package:lx_music_flutter/core/widgets/app_notification.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  testWidgets('top notification consumes one playback message exactly once',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: AppNotificationHost(
            child: const PlayerMessageListener(
              child: Scaffold(body: SizedBox.expand()),
            ),
          ),
        ),
      ),
    );

    container.read(playerMessageProvider.notifier).state = '播放失败';
    await tester.pump();

    expect(find.text('播放失败'), findsOneWidget);
    expect(container.read(playerMessageProvider), isNull);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('播放失败'), findsNothing);
  });

  testWidgets('new notification immediately replaces the current one',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AppNotificationHost(child: Scaffold(body: SizedBox.expand())),
      ),
    );

    expect(showAppNotification('第一条通知'), isTrue);
    await tester.pump();
    expect(find.text('第一条通知'), findsOneWidget);

    expect(showAppNotification('第二条通知'), isTrue);
    await tester.pump();
    expect(find.text('第一条通知'), findsNothing);
    expect(find.text('第二条通知'), findsOneWidget);
  });

  testWidgets('notification text explicitly disables inherited decoration',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DefaultTextStyle(
          style: TextStyle(decoration: TextDecoration.underline),
          child: AppNotificationHost(child: Scaffold(body: SizedBox.expand())),
        ),
      ),
    );

    expect(showAppNotification('无下划线'), isTrue);
    await tester.pump();

    final text = tester.widget<Text>(find.text('无下划线'));
    expect(text.style?.decoration, TextDecoration.none);
  });

  testWidgets('new notification replaces one that is dismissing',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AppNotificationHost(child: Scaffold(body: SizedBox.expand())),
      ),
    );

    expect(showAppNotification('即将消失'), isTrue);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(showAppNotification('退场期间的新通知'), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('即将消失'), findsNothing);
    expect(find.text('退场期间的新通知'), findsOneWidget);
  });

  testWidgets('tapping a truncated notification copies its full content',
      (tester) async {
    final clipboardWrites = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardWrites.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    const fullMessage = '这是一条很长的通知，界面最多显示两行，但点击后必须复制没有经过省略的完整原始内容。';
    await tester.pumpWidget(
      const MaterialApp(
        home: AppNotificationHost(child: Scaffold(body: SizedBox.expand())),
      ),
    );

    expect(showAppNotification(fullMessage), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text(fullMessage));
    await tester.pump();

    expect(clipboardWrites, [fullMessage]);
  });

  testWidgets('message remains pending until a notification host exists',
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
