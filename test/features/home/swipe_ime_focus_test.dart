import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/home/presentation/main_scaffold.dart';

/// 回归：父级横滑不得与搜索框首击抢 gesture arena。
void main() {
  testWidgets('tap TextField under SwipeBranchContainer keeps focus',
      (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: SwipeBranchContainer(
            currentIndex: 1,
            onSelect: (_) {},
            children: [
              const ColoredBox(color: Colors.red),
              Scaffold(
                resizeToAvoidBottomInset: false,
                body: Center(
                  child: SizedBox(
                    width: 280,
                    child: TextField(
                      focusNode: focusNode,
                      decoration: const InputDecoration(hintText: '搜索'),
                    ),
                  ),
                ),
              ),
              const ColoredBox(color: Colors.green),
              const ColoredBox(color: Colors.blue),
            ],
          ),
        ),
      ),
    );

    expect(focusNode.hasFocus, isFalse);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    // 再泵一帧：若父级 drag 抢 arena，focus 会在随后丢失
    await tester.pump(const Duration(milliseconds: 100));

    expect(focusNode.hasFocus, isTrue);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('horizontal drag on non-editable area still switches branch',
      (tester) async {
    var selected = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: StatefulBuilder(
            builder: (context, setState) {
              return SwipeBranchContainer(
                currentIndex: selected,
                onSelect: (i) => setState(() => selected = i),
                children: const [
                  ColoredBox(
                    key: Key('home'),
                    color: Colors.red,
                    child: SizedBox.expand(),
                  ),
                  ColoredBox(
                    key: Key('search'),
                    color: Colors.orange,
                    child: SizedBox.expand(),
                  ),
                  ColoredBox(
                    key: Key('playlist'),
                    color: Colors.green,
                    child: SizedBox.expand(),
                  ),
                  ColoredBox(
                    key: Key('settings'),
                    color: Colors.blue,
                    child: SizedBox.expand(),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    // 在空白区域右滑回首页
    await tester.drag(find.byKey(const Key('search')), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(selected, 0);
  });

  testWidgets('programmatic branch selection animates before switching',
      (tester) async {
    var selected = 0;
    final key = GlobalKey<SwipeBranchContainerState>();

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: StatefulBuilder(
            builder: (context, setState) {
              return SwipeBranchContainer(
                key: key,
                currentIndex: selected,
                onSelect: (i) => setState(() => selected = i),
                children: const [
                  ColoredBox(key: Key('page-0'), color: Colors.red),
                  ColoredBox(key: Key('page-1'), color: Colors.orange),
                  ColoredBox(key: Key('page-2'), color: Colors.green),
                  ColoredBox(key: Key('page-3'), color: Colors.blue),
                ],
              );
            },
          ),
        ),
      ),
    );

    final selection = key.currentState!.select(3);
    await tester.pump();
    expect(selected, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('page-3')), findsOneWidget);
    expect(find.byKey(const Key('page-1')), findsNothing);

    await tester.pumpAndSettle();
    await selection;
    expect(selected, 3);
  });
}
