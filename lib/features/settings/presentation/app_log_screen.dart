import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/app_log.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_notification.dart';

class AppLogScreen extends StatefulWidget {
  AppLogScreen({super.key, AppLog? log}) : log = log ?? AppLog.instance;

  final AppLog log;

  @override
  State<AppLogScreen> createState() => _AppLogScreenState();
}

class _AppLogScreenState extends State<AppLogScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _followLatest = true;

  @override
  void initState() {
    super.initState();
    widget.log.entries.addListener(_scrollToLatest);
  }

  @override
  void dispose() {
    widget.log.entries.removeListener(_scrollToLatest);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToLatest() {
    if (!_followLatest) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _copyLogs() async {
    final text = widget.log.exportText();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showAppNotification('日志已复制', type: AppNotificationType.success);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<AppLogEntry>>(
      valueListenable: widget.log.entries,
      builder: (context, entries, _) => Scaffold(
        appBar: AppBar(
          title: const Text('实时诊断日志'),
          actions: [
            IconButton(
              tooltip: '复制全部',
              onPressed: entries.isEmpty ? null : _copyLogs,
              icon: const Icon(Icons.copy_all_outlined),
            ),
            IconButton(
              tooltip: '清空内存日志',
              onPressed: entries.isEmpty ? null : widget.log.clear,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 9),
              color: AppColors.fill(context),
              child: Text(
                '仅保存在当前运行内存；关闭或重启应用后自动清空。',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.secondaryText(context),
                ),
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        '暂无日志',
                        style: TextStyle(color: AppColors.mutedText(context)),
                      ),
                    )
                  : NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is ScrollUpdateNotification &&
                            _scrollController.hasClients) {
                          final position = _scrollController.position;
                          _followLatest =
                              position.maxScrollExtent - position.pixels < 48;
                        }
                        return false;
                      },
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(12),
                        itemCount: entries.length,
                        itemBuilder: (context, index) =>
                            _LogRow(entry: entries[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final AppLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) {
      AppLogLevel.info => AppColors.secondaryText(context),
      AppLogLevel.warning => Colors.orangeAccent,
      AppLogLevel.error => AppColors.error,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SelectableText(
        entry.text,
        style: TextStyle(
          color: color,
          fontFamily: 'monospace',
          fontSize: 11,
          height: 1.35,
        ),
      ),
    );
  }
}
