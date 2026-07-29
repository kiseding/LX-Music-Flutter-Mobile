import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../cloud/presentation/cloud_provider.dart';
import '../../cloud/domain/cloud_api_client.dart';
import '../../playlist/presentation/playlist_provider.dart';
import '../../player/domain/music_item.dart';
import 'cloud_playlist_merge.dart';

/// 同步页：对接 workers 云端（账号 + 歌单），不再强制首次启动登录。
class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isLoginMode = true;
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  CloudApiClient get _api => ref.read(cloudApiProvider);

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(cloudSessionProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          '同步 / 云端账号',
          style: TextStyle(color: AppColors.onScaffold(context)),
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        iconTheme: IconThemeData(color: AppColors.onScaffold(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        children: [
          _card(
            child: ListTile(
              leading: Icon(Icons.dns_outlined, color: AppColors.amber),
              title: Text(
                'Workers 服务器',
                style: TextStyle(color: AppColors.onScaffold(context)),
              ),
              subtitle: Text(
                session.baseUrl ?? '未配置（例如 https://xxx.workers.dev）',
                style: TextStyle(
                  color: session.baseUrl != null
                      ? AppColors.mutedText(context)
                      : AppColors.error,
                  fontSize: 12,
                ),
              ),
              trailing: Icon(
                Icons.edit,
                color: AppColors.mutedText(context),
                size: 18,
              ),
              onTap: _editServerUrl,
            ),
          ),
          const SizedBox(height: 12),
          _card(
            child: ListTile(
              leading: Icon(
                session.loggedIn ? Icons.cloud_done : Icons.cloud_off,
                color: session.loggedIn
                    ? AppColors.success
                    : AppColors.mutedText(context),
              ),
              title: Text(
                session.loggedIn ? '已登录：${session.username}' : '未登录',
                style: TextStyle(color: AppColors.onScaffold(context)),
              ),
              subtitle: Text(
                session.loggedIn
                    ? '角色：${session.role ?? 'user'}'
                    : '登录后可同步云端歌单',
                style: TextStyle(
                  color: AppColors.mutedText(context),
                  fontSize: 12,
                ),
              ),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.fill(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: AppColors.secondaryText(context),
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (!session.loggedIn) _buildAuth(),
          if (session.loggedIn) ...[
            _buildLoggedInActions(session),
            if (session.role == 'admin') ...[
              const SizedBox(height: 16),
              _buildAdminSection(),
            ],
          ],
          const SizedBox(height: 24),
          Text(
            '说明：在此配置并登录 workers 后端。搜歌/播放仍在本机完成，云端只负责账号与歌单。',
            style: TextStyle(color: AppColors.mutedText(context), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Card(
      color: AppColors.card(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.cardBorder(context)),
      ),
      child: child,
    );
  }

  Widget _buildAuth() {
    return _card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ChoiceChip(
                  label: const Text('登录'),
                  selected: _isLoginMode,
                  onSelected: (_) => setState(() => _isLoginMode = true),
                  selectedColor: AppColors.amber,
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('注册'),
                  selected: !_isLoginMode,
                  onSelected: (_) => setState(() => _isLoginMode = false),
                  selectedColor: AppColors.amber,
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userCtrl,
              style: TextStyle(color: AppColors.onScaffold(context)),
              decoration: InputDecoration(
                labelText: '用户名',
                labelStyle: TextStyle(color: AppColors.mutedText(context)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtrl,
              obscureText: true,
              style: TextStyle(color: AppColors.onScaffold(context)),
              decoration: InputDecoration(
                labelText: '密码',
                labelStyle: TextStyle(color: AppColors.mutedText(context)),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
              onPressed: _busy ? null : _submitAuth,
              child: Text(_busy ? '请稍候…' : (_isLoginMode ? '登录' : '注册')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoggedInActions(CloudSessionState session) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
          ),
          onPressed: _busy ? null : _pullPlaylists,
          icon: Icon(Icons.cloud_download),
          label: Text(_busy ? '同步中…' : '从云端拉取歌单'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () async {
            await ref.read(cloudSessionProvider.notifier).logout();
            setState(() => _message = '已退出登录');
          },
          child: const Text('退出登录', style: TextStyle(color: AppColors.error)),
        ),
      ],
    );
  }

  Widget _buildAdminSection() {
    return _card(
      child: ListTile(
        leading: Icon(Icons.admin_panel_settings, color: AppColors.amber),
        title: Text(
          '用户管理（管理员）',
          style: TextStyle(color: AppColors.onScaffold(context)),
        ),
        subtitle: Text(
          '创建 / 删除 / 重置密码',
          style: TextStyle(color: AppColors.mutedText(context), fontSize: 12),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: AppColors.mutedText(context),
        ),
        onTap: _openAdminUsers,
      ),
    );
  }

  Future<void> _editServerUrl() async {
    final ctrl = TextEditingController(
      text: ref.read(cloudSessionProvider).baseUrl ?? '',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text(
          'Workers 地址',
          style: TextStyle(color: AppColors.onScaffold(context)),
        ),
        content: SingleChildScrollView(
          child: TextField(
            controller: ctrl,
            style: TextStyle(color: AppColors.onScaffold(context)),
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: 'https://lx-music-api.xxx.workers.dev',
              hintStyle: TextStyle(color: AppColors.mutedText(context)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存', style: TextStyle(color: AppColors.amber)),
          ),
        ],
      ),
    );
    if (ok == true) {
      final url = ctrl.text.trim();
      try {
        await ref.read(cloudSessionProvider.notifier).setBaseUrl(url);
        final alive = await _api.ping();
        setState(() => _message = alive ? '服务器可达' : '保存成功，但健康检查失败（部署后重试）');
      } on ArgumentError catch (error) {
        setState(
            () => _message = error.message?.toString() ?? '服务器地址必须使用 HTTPS');
      }
    }
  }

  Future<void> _submitAuth() async {
    if ((ref.read(cloudSessionProvider).baseUrl ?? '').isEmpty) {
      setState(() => _message = '请先填写服务器地址');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    final ok = _isLoginMode
        ? await ref.read(cloudSessionProvider.notifier).login(user, pass)
        : await ref.read(cloudSessionProvider.notifier).register(user, pass);
    setState(() {
      _busy = false;
      _message = ok ? '登录成功' : (ref.read(cloudSessionProvider).error ?? '失败');
    });
  }

  Future<void> _pullPlaylists() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final data = await _api.fetchUserList();
      final love = (data['loveList'] as List?) ?? [];
      final userList = (data['userList'] as List?) ?? [];
      final result = await mergeAndPersistCloudPlaylists(
        service: ref.read(playlistServiceProvider),
        love: love,
        userList: userList,
        decodeSong: _songFromCloud,
      );
      if (!mounted) return;
      setState(
        () => _message =
            '已同步：喜欢 ${result.favoriteSongCount} 首，歌单 ${result.acceptedPlaylistCount} 个',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '同步失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  MusicItem? _songFromCloud(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final source = m['source']?.toString() ?? 'tx';
    final mid = m['songmid']?.toString() ?? m['hash']?.toString() ?? '';
    if (mid.isEmpty && (m['name']?.toString().isEmpty ?? true)) return null;
    return MusicItem(
      id: mid.isNotEmpty ? mid : '${m['name']}_${m['singer']}',
      name: m['name']?.toString() ?? '',
      singer: m['singer']?.toString() ?? '',
      album: m['albumName']?.toString() ?? '',
      source: source,
      platform: source,
      artwork: m['img']?.toString(),
      songmid: mid,
      hash: m['hash']?.toString() ?? mid,
      meta: m,
    );
  }

  Future<void> _openAdminUsers() async {
    setState(() => _busy = true);
    try {
      final users = await _api.adminListUsers();
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        backgroundColor: AppColors.dialogBg(context),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        isScrollControlled: true,
        builder: (ctx) {
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.7,
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '用户列表',
                      style: TextStyle(
                        color: AppColors.onScaffold(context),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: users.length,
                      itemBuilder: (_, i) {
                        final u = users[i];
                        return ListTile(
                          title: Text(
                            '${u['username']} (${u['role']})',
                            style: TextStyle(
                              color: AppColors.onScaffold(context),
                            ),
                          ),
                          subtitle: Text(
                            'id=${u['id']}',
                            style: TextStyle(
                              color: AppColors.mutedText(context),
                              fontSize: 11,
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete,
                              color: AppColors.error,
                            ),
                            onPressed: () async {
                              try {
                                await _api.adminDeleteUser(
                                  int.parse(u['id'].toString()),
                                );
                                if (ctx.mounted) Navigator.pop(ctx);
                                setState(
                                  () => _message = '已删除 ${u['username']}',
                                );
                              } catch (e) {
                                setState(() => _message = '删除失败: $e');
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(12),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onPrimary,
                      ),
                      onPressed: () async {
                        final u = TextEditingController();
                        final p = TextEditingController();
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (d) => AlertDialog(
                            backgroundColor: AppColors.dialogBg(context),
                            title: Text(
                              '新建用户',
                              style: TextStyle(
                                color: AppColors.onScaffold(context),
                              ),
                            ),
                            content: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextField(
                                    controller: u,
                                    style: TextStyle(
                                      color: AppColors.onScaffold(context),
                                    ),
                                    decoration: InputDecoration(
                                      labelText: '用户名',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: p,
                                    obscureText: true,
                                    style: TextStyle(
                                      color: AppColors.onScaffold(context),
                                    ),
                                    decoration: InputDecoration(
                                      labelText: '密码',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(d, false),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(d, true),
                                child: const Text(
                                  '创建',
                                  style: TextStyle(color: AppColors.amber),
                                ),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          try {
                            await _api.adminCreateUser(u.text.trim(), p.text);
                            if (ctx.mounted) Navigator.pop(ctx);
                            setState(() => _message = '已创建用户');
                          } catch (e) {
                            setState(() => _message = '创建失败: $e');
                          }
                        }
                      },
                      child: const Text('新建用户'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } catch (e) {
      setState(() => _message = '加载用户失败: $e');
    } finally {
      setState(() => _busy = false);
    }
  }
}
