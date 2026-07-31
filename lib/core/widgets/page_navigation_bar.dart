import 'package:flutter/material.dart';

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
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
        child: Row(
          children: [
            IconButton(
              tooltip: '上一页',
              onPressed: pageIndex == 0
                  ? null
                  : () => onPageChanged(pageIndex - 1),
              icon: const Icon(Icons.chevron_left, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 20),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Center(
                child: TextButton(
                  onPressed: () => _showPagePickerDialog(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 2,
                    ),
                    minimumSize: const Size(0, 20),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    '第 ${pageIndex + 1} / $pageCount 页',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '下一页',
              onPressed: pageIndex + 1 >= pageCount
                  ? null
                  : () => onPageChanged(pageIndex + 1),
              icon: const Icon(Icons.chevron_right, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 20),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPagePickerDialog(BuildContext context) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('选择页码'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320, minWidth: 300),
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.5,
              ),
              itemCount: pageCount,
              itemBuilder: (context, index) {
                final page = index + 1;
                final isCurrent = index == pageIndex;
                return Material(
                  color: isCurrent
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => Navigator.pop(context, page),
                    child: Center(
                      child: Text(
                        '$page',
                        style: TextStyle(
                          color: isCurrent
                              ? scheme.onPrimaryContainer
                              : scheme.onSurface,
                          fontWeight: isCurrent ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
    if (selected == null) return;
    onPageChanged((selected - 1).clamp(0, pageCount - 1).toInt());
  }
}
