import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/widgets/loading_widget.dart';
import 'package:lx_music_flutter/core/widgets/empty_widget.dart';
import 'package:lx_music_flutter/core/widgets/error_boundary.dart';

void main() {
  group('LoadingWidget', () {
    testWidgets('shows loading indicator', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LoadingWidget(),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows hint text when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LoadingWidget(hint: '加载中...'),
          ),
        ),
      );

      expect(find.text('加载中...'), findsOneWidget);
    });
  });

  group('EmptyWidget', () {
    testWidgets('shows message', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyWidget(message: '暂无数据'),
          ),
        ),
      );

      expect(find.text('暂无数据'), findsOneWidget);
    });

    testWidgets('shows action button when provided', (tester) async {
      bool actionCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyWidget(
              message: '暂无数据',
              actionText: '刷新',
              onAction: () => actionCalled = true,
            ),
          ),
        ),
      );

      expect(find.text('刷新'), findsOneWidget);

      await tester.tap(find.text('刷新'));
      expect(actionCalled, true);
    });
  });

  group('ErrorBoundary', () {
    testWidgets('renders child when no error', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ErrorBoundary(
            child: const Text('Normal Content'),
          ),
        ),
      );

      expect(find.text('Normal Content'), findsOneWidget);
    });
  });
}
