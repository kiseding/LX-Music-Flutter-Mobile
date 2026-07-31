import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

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
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildArrowButton(context, isPrevious: true),
              _buildPageTextButton(context),
              _buildArrowButton(context, isPrevious: false),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageTextButton(BuildContext context) {
    return TextButton(
      onPressed: () => _showPagePickerDialog(context),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        minimumSize: const Size(0, 20),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        '第 ${pageIndex + 1} / $pageCount 页',
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  Widget _buildArrowButton(BuildContext context, {required bool isPrevious}) {
    final enabled = isPrevious ? pageIndex > 0 : pageIndex + 1 < pageCount;
    final background = AppColors.fill2(context);
    final foreground = enabled
        ? AppColors.secondaryText(context)
        : AppColors.mutedText(context).withValues(alpha: 0.5);
    return Center(
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: background,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.cardBorder(context)),
        ),
        child: IconButton(
          tooltip: isPrevious ? '上一页' : '下一页',
          onPressed: enabled
              ? () => onPageChanged(pageIndex + (isPrevious ? -1 : 1))
              : null,
          icon: Icon(
            isPrevious ? Icons.chevron_left : Icons.chevron_right,
            size: 16,
            color: foreground,
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          visualDensity: VisualDensity.compact,
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
