import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/app_log.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_notification.dart';

OverlayEntry? _diagnosticLogEntry;
final _diagnosticLogKey = GlobalKey<_DiagnosticLogOverlayState>();

void showDiagnosticLogOverlay(BuildContext context) {
  final existing = _diagnosticLogKey.currentState;
  if (existing != null) {
    existing.expand();
    return;
  }
  final overlay = Overlay.of(context, rootOverlay: true);
  final log = AppLog.instance;
  log
    ..clear()
    ..start();
  _diagnosticLogEntry = OverlayEntry(
    builder: (_) => _DiagnosticLogOverlay(key: _diagnosticLogKey, log: log),
  );
  overlay.insert(_diagnosticLogEntry!);
}

void _closeDiagnosticLogOverlay() {
  AppLog.instance.stop();
  _diagnosticLogEntry?.remove();
  _diagnosticLogEntry = null;
}

class _DiagnosticLogOverlay extends StatefulWidget {
  const _DiagnosticLogOverlay({super.key, required this.log});

  final AppLog log;

  @override
  State<_DiagnosticLogOverlay> createState() => _DiagnosticLogOverlayState();
}

class _DiagnosticLogOverlayState extends State<_DiagnosticLogOverlay> {
  bool _minimized = false;
  Offset? _position;

  void expand() => setState(() => _minimized = false);

  @override
  Widget build(BuildContext context) {
    if (!_minimized) {
      return Material(
        color: Colors.black54,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720, maxHeight: 680),
              child: FractionallySizedBox(
                widthFactor: 0.92,
                heightFactor: 0.78,
                child: AppLogScreen(
                  log: widget.log,
                  onMinimize: () => setState(() => _minimized = true),
                  onClose: _closeDiagnosticLogOverlay,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final media = MediaQuery.of(context);
    const size = Size(112, 40);
    final safeTop = media.padding.top + 8;
    final maxLeft = media.size.width - size.width - 8;
    final maxTop = media.size.height - media.padding.bottom - size.height - 8;
    final position = _position ?? Offset(maxLeft, safeTop + 72);
    return Positioned(
      left: position.dx.clamp(8, maxLeft),
      top: position.dy.clamp(safeTop, maxTop),
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            final next = position + details.delta;
            _position = Offset(
              next.dx.clamp(8, maxLeft),
              next.dy.clamp(safeTop, maxTop),
            );
          });
        },
        onTap: expand,
        child: Material(
          elevation: 8,
          color: AppColors.card(context),
          shape: StadiumBorder(
            side: BorderSide(color: AppColors.cardBorder(context)),
          ),
          child: ValueListenableBuilder<List<AppLogEntry>>(
            valueListenable: widget.log.entries,
            builder: (context, entries, _) => SizedBox(
              width: size.width,
              height: size.height,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bug_report_outlined,
                    size: 16,
                    color: AppColors.accentOf(context),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '诊断 ${entries.length}',
                    style: TextStyle(
                      color: AppColors.onScaffold(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppLogScreen extends StatefulWidget {
  AppLogScreen({super.key, AppLog? log, this.onMinimize, this.onClose})
    : log = log ?? AppLog.instance;

  final AppLog log;
  final VoidCallback? onMinimize;
  final VoidCallback? onClose;

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
      builder: (context, entries, _) => Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('实时诊断日志'),
            actions: [
              if (widget.onMinimize != null)
                IconButton(
                  tooltip: '最小化',
                  onPressed: widget.onMinimize,
                  icon: const Icon(Icons.remove),
                ),
              IconButton(
                tooltip: '复制全部',
                onPressed: entries.isEmpty ? null : _copyLogs,
                icon: const Icon(Icons.copy_all_outlined),
              ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: '关闭诊断日志',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
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
