import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../../../core/io/bounded_input.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/custom_source.dart';
import '../domain/custom_source_service.dart';
import 'custom_source_provider.dart';

class CustomSourceScreen extends ConsumerWidget {
  const CustomSourceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(customSourcesProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.onScaffold(context)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '自定义源',
          style: TextStyle(color: AppColors.onScaffold(context), fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.file_open, color: AppColors.onScaffold(context)),
            tooltip: '导入本地脚本',
            onPressed: () => _pickAndImportFile(context, ref),
          ),
          IconButton(
            icon: Icon(Icons.cloud_download, color: AppColors.onScaffold(context)),
            tooltip: '通过链接导入',
            onPressed: () => _showUrlImportDialog(context, ref),
          ),
          IconButton(
            icon: Icon(Icons.add, color: AppColors.onScaffold(context)),
            tooltip: '手动添加',
            onPressed: () => _showAddDialog(context, ref),
          ),
          IconButton(
            icon: Icon(Icons.link, color: AppColors.onScaffold(context)),
            tooltip: '粘贴脚本',
            onPressed: () => _showImportDialog(context, ref),
          ),
        ],
      ),
      body: sources.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.code, size: 64, color: AppColors.mutedText(context)),
                  const SizedBox(height: 16),
                  Text('暂无自定义源', style: TextStyle(color: AppColors.mutedText(context), fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('点击右上角 + 添加自定义源', style: TextStyle(color: AppColors.mutedText(context), fontSize: 14)),
                ],
              ),
            )
          : ListView.builder(
              padding: EdgeInsets.all(16),
              itemCount: sources.length,
              itemBuilder: (context, index) {
                final source = sources[index];
                return _buildSourceItem(context, ref, source);
              },
            ),
    );
  }

  Widget _buildSourceItem(BuildContext context, WidgetRef ref, CustomSource source) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      style: TextStyle(
                        color: AppColors.onScaffold(context),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'v${source.version} · ${source.author}',
                      style: TextStyle(color: AppColors.mutedText(context), fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: source.isEnabled,
                activeThumbColor: AppColors.accentOf(context),
                onChanged: (value) {
                  ref.read(customSourcesProvider.notifier).toggleSource(source.id);
                },
              ),
            ],
          ),
          if (source.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              source.description,
              style: TextStyle(color: AppColors.secondaryText(context), fontSize: 14),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: Icon(Icons.terminal, size: 16),
                label: const Text('日志'),
                onPressed: () => _showLogDialog(context, ref, source),
              ),
              TextButton.icon(
                icon: Icon(Icons.edit, size: 16),
                label: const Text('编辑'),
                onPressed: () => _showEditDialog(context, ref, source),
              ),
              TextButton.icon(
                icon: Icon(Icons.share, size: 16),
                label: const Text('导出'),
                onPressed: () => _showExportDialog(context, ref, source),
              ),
              TextButton.icon(
                icon: Icon(Icons.delete, size: 16, color: Colors.red),
                label: const Text('删除', style: TextStyle(color: Colors.red)),
                onPressed: () => _showDeleteDialog(context, ref, source),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndImportFile(BuildContext context, WidgetRef ref) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['js'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final bytes = await readFileBytesBounded(
          file,
          maximumBytes: CustomSourceService.maximumScriptBytes,
        );
        final content = utf8.decode(bytes);

        final success = await ref
            .read(customSourcesProvider.notifier)
            .importLxMusicScript(content);
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(success ? '导入脚本成功' : '导入失败，脚本格式错误'),
              backgroundColor: success ? Colors.green : Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取文件失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showAddDialog(BuildContext context, WidgetRef ref) {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final authorController = TextEditingController();
    final scriptController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text('添加自定义源', style: TextStyle(color: AppColors.onScaffold(context))),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTextField(context, nameController, '源名称'),
              const SizedBox(height: 8),
              _buildTextField(context, descController, '描述'),
              const SizedBox(height: 8),
              _buildTextField(context, authorController, '作者'),
              const SizedBox(height: 8),
              _buildTextField(context, scriptController, '脚本', maxLines: 10),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消', style: TextStyle(color: AppColors.mutedText(context))),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.isNotEmpty && scriptController.text.isNotEmpty) {
                final source = CustomSource(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameController.text,
                  description: descController.text,
                  version: '1.0.0',
                  author: authorController.text,
                  script: scriptController.text,
                  createdAt: DateTime.now(),
                  updatedAt: DateTime.now(),
                );
                ref.read(customSourcesProvider.notifier).addSource(source);
                Navigator.pop(context);
              }
            },
            child: Text('添加', style: TextStyle(color: AppColors.accentOf(context))),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context, WidgetRef ref, CustomSource source) {
    final nameController = TextEditingController(text: source.name);
    final descController = TextEditingController(text: source.description);
    final authorController = TextEditingController(text: source.author);
    final scriptController = TextEditingController(text: source.script);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text('编辑自定义源', style: TextStyle(color: AppColors.onScaffold(context))),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTextField(context, nameController, '源名称'),
              const SizedBox(height: 8),
              _buildTextField(context, descController, '描述'),
              const SizedBox(height: 8),
              _buildTextField(context, authorController, '作者'),
              const SizedBox(height: 8),
              _buildTextField(context, scriptController, '脚本', maxLines: 10),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消', style: TextStyle(color: AppColors.mutedText(context))),
          ),
          TextButton(
            onPressed: () {
              final updated = source.copyWith(
                name: nameController.text,
                description: descController.text,
                author: authorController.text,
                script: scriptController.text,
              );
              ref.read(customSourcesProvider.notifier).updateSource(updated);
              Navigator.pop(context);
            },
            child: Text('保存', style: TextStyle(color: AppColors.accentOf(context))),
          ),
        ],
      ),
    );
  }

  void _showUrlImportDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: AppColors.dialogBg(context),
          title: Text('通过链接导入', style: TextStyle(color: AppColors.onScaffold(context))),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '请输入脚本文件的直接下载链接',
                style: TextStyle(color: AppColors.mutedText(context), fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                style: TextStyle(color: AppColors.onScaffold(context)),
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'https://...',
                  hintStyle: TextStyle(color: AppColors.mutedText(context)),
                  filled: true,
                  fillColor: AppColors.fill2(context),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
              if (isLoading) ...[
                const SizedBox(height: 16),
                Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentOf(context)),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(context),
              child: Text('取消', style: TextStyle(color: AppColors.mutedText(context))),
            ),
            TextButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      final url = controller.text.trim();
                      if (url.isEmpty || !url.startsWith('https://')) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请输入有效的 HTTPS 链接')),
                        );
                        return;
                      }

                      setState(() => isLoading = true);
                      final success = await ref.read(customSourcesProvider.notifier).importSourceFromUrl(url);
                      setState(() => isLoading = false);

                      if (context.mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(success ? '导入成功' : '导入失败，请检查链接或脚本格式'),
                            backgroundColor: success ? Colors.green : Colors.red,
                          ),
                        );
                      }
                    },
              child: Text('导入', style: TextStyle(color: AppColors.accentOf(context))),
            ),
          ],
        ),
      ),
    );
  }

  void _showImportDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text('导入自定义源', style: TextStyle(color: AppColors.onScaffold(context))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '支持 LX Music 格式脚本',
              style: TextStyle(color: AppColors.mutedText(context), fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              style: TextStyle(color: AppColors.onScaffold(context), fontFamily: 'monospace'),
              maxLines: 10,
              decoration: InputDecoration(
                hintText: '粘贴 LX Music 脚本或 JSON 配置...',
                hintStyle: TextStyle(color: AppColors.mutedText(context)),
                filled: true,
                fillColor: AppColors.fill2(context),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消', style: TextStyle(color: AppColors.mutedText(context))),
          ),
          TextButton(
            onPressed: () async {
              final text = controller.text.trim();
              bool success = false;
              
              // 检查是否是 LX Music 格式脚本
              if (text.contains('globalThis.lx') || text.contains('EVENT_NAMES')) {
                success = await ref.read(customSourcesProvider.notifier).importLxMusicScript(text);
              } else {
                success = await ref.read(customSourcesProvider.notifier).importSource(text);
              }
              
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(success ? '导入成功' : '导入失败，请检查脚本格式'),
                  backgroundColor: success ? Colors.green : Colors.red,
                ),
              );
            },
            child: Text('导入', style: TextStyle(color: AppColors.accentOf(context))),
          ),
        ],
      ),
    );
  }

  void _showExportDialog(BuildContext context, WidgetRef ref, CustomSource source) {
    final jsonStr = const JsonEncoder.withIndent('  ').convert(source.toJson());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text('导出自定义源', style: TextStyle(color: AppColors.onScaffold(context))),
        content: Container(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              jsonStr,
              style: TextStyle(color: AppColors.onScaffold(context), fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('关闭', style: TextStyle(color: AppColors.mutedText(context))),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, WidgetRef ref, CustomSource source) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text('删除自定义源', style: TextStyle(color: AppColors.onScaffold(context))),
        content: Text('确定要删除"${source.name}"吗？', style: TextStyle(color: AppColors.secondaryText(context))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消', style: TextStyle(color: AppColors.mutedText(context))),
          ),
          TextButton(
            onPressed: () {
              ref.read(customSourcesProvider.notifier).deleteSource(source.id);
              Navigator.pop(context);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showLogDialog(BuildContext context, WidgetRef ref, CustomSource source) {
    showDialog(
      context: context,
      builder: (context) => _LogConsole(source: source),
    );
  }

  Widget _buildTextField(BuildContext context, TextEditingController controller, String label, {int maxLines = 1}) {
    return TextField(
      controller: controller,
      style: TextStyle(color: AppColors.onScaffold(context)),
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: AppColors.mutedText(context)),
        filled: true,
        fillColor: AppColors.fill2(context),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      ),
    );
  }
}

class _LogConsole extends ConsumerStatefulWidget {
  final CustomSource source;
  const _LogConsole({required this.source});

  @override
  ConsumerState<_LogConsole> createState() => _LogConsoleState();
}

class _LogConsoleState extends ConsumerState<_LogConsole> {
  final List<Map<String, dynamic>> _logs = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _listenLogs();
  }

  void _listenLogs() {
    ref.read(customSourcesProvider.notifier)
        .getEventStream(widget.source.id)
        .listen((event) {
          if (mounted) {
            setState(() {
              _logs.add({
                ...event,
                'timestamp': DateTime.now(),
              });
              // 自动滚动到底部
              Future.delayed(const Duration(milliseconds: 100), () {
                if (_scrollController.hasClients) {
                  _scrollController.animateTo(
                    _scrollController.position.maxScrollExtent,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  );
                }
              });
            });
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.dialogBg(context),
      title: Row(
        children: [
          Icon(Icons.terminal, color: AppColors.onScaffold(context), size: 20),
          const SizedBox(width: 8),
          Text('${widget.source.name} 日志', style: TextStyle(color: AppColors.onScaffold(context), fontSize: 16)),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.delete_sweep, color: AppColors.mutedText(context), size: 20),
            onPressed: () => setState(() => _logs.clear()),
          ),
        ],
      ),
      content: Container(
        width: double.maxFinite,
        height: 400,
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.fill(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.cardBorder(context)),
        ),
        child: _logs.isEmpty
            ? Center(child: Text('暂无日志', style: TextStyle(color: AppColors.mutedText(context))))
            : ListView.builder(
                controller: _scrollController,
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  final log = _logs[index];
                  final type = log['type'];
                  Color color = AppColors.secondaryText(context);
                  if (type == 'error') color = AppColors.error;
                  if (type == 'event') color = AppColors.accentOf(context);

                  return Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                        children: [
                          TextSpan(
                            text: '[${_formatTime(log['timestamp'])}] ',
                            style: TextStyle(color: AppColors.mutedText(context)),
                          ),
                          TextSpan(
                            text: '${log['message'] ?? log['event'] ?? ''}\n',
                            style: TextStyle(color: color),
                          ),
                          if (log['data'] != null)
                            TextSpan(
                              text: '  ${json.encode(log['data'])}\n',
                              style: TextStyle(color: AppColors.mutedText(context), fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('关闭', style: TextStyle(color: AppColors.mutedText(context))),
        ),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}
