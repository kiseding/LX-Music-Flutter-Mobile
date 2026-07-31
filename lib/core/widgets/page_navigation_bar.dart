import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PageNavigationBar extends StatelessWidget {
  const PageNavigationBar({
    super.key,
    required this.pageIndex,
    required this.pageCount,
    required this.onPageChanged,
  });

  final int pageIndex;
  final int pageCount;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    if (pageCount <= 1) return const SizedBox.shrink();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            IconButton(
              tooltip: '上一页',
              onPressed: pageIndex == 0
                  ? null
                  : () => onPageChanged(pageIndex - 1),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Center(
                child: Text('第 ${pageIndex + 1} / $pageCount 页'),
              ),
            ),
            TextButton(
              onPressed: () => _showJumpDialog(context),
              child: const Text('跳转'),
            ),
            IconButton(
              tooltip: '下一页',
              onPressed: pageIndex + 1 >= pageCount
                  ? null
                  : () => onPageChanged(pageIndex + 1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showJumpDialog(BuildContext context) async {
    final controller = TextEditingController(text: '${pageIndex + 1}');
    final selectedPage = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳转到页码'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(hintText: '1 - $pageCount'),
          onSubmitted: (value) => Navigator.pop(context, int.tryParse(value)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text)),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (selectedPage == null) return;
    onPageChanged((selectedPage - 1).clamp(0, pageCount - 1).toInt());
  }
}
