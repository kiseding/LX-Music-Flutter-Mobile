import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/logging/app_log.dart';
import 'package:lx_music_flutter/features/settings/presentation/app_log_screen.dart';

void main() {
  testWidgets('shows live entries and enables copy when available', (tester) async {
    final log = AppLog();
    log.record('audio', 'route changed');

    await tester.pumpWidget(
      MaterialApp(home: AppLogScreen(log: log)),
    );

    expect(find.textContaining('route changed'), findsOneWidget);
    expect(find.byTooltip('复制全部'), findsOneWidget);
    final copyButton = find.widgetWithIcon(
      IconButton,
      Icons.copy_all_outlined,
    );
    expect(copyButton, findsOneWidget);
    expect(
      tester.widget<IconButton>(copyButton).onPressed,
      isNotNull,
    );
  });
}
