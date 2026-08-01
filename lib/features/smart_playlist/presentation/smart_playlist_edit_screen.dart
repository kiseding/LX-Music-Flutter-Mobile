import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../domain/smart_playlist.dart';
import 'smart_playlist_provider.dart';

class SmartPlaylistEditScreen extends ConsumerStatefulWidget {
  const SmartPlaylistEditScreen({super.key, required this.smart});

  final SmartPlaylist smart;

  @override
  ConsumerState<SmartPlaylistEditScreen> createState() =>
      _SmartPlaylistEditScreenState();
}

class _SmartPlaylistEditScreenState
    extends ConsumerState<SmartPlaylistEditScreen> {
  late final TextEditingController _nameController;
  late SmartPlaylistCombinator _groupCombinator;
  late List<SmartPlaylistRuleGroup> _groups;
  late SmartPlaylistSortField _sortField;
  late SmartPlaylistSortDirection _sortDirection;
  late TextEditingController _limitController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.smart.name);
    _groupCombinator = widget.smart.groupCombinator;
    _groups = List.of(widget.smart.groups);
    if (_groups.isEmpty) {
      _groups = [const SmartPlaylistRuleGroup()];
    }
    _sortField = widget.smart.sortField;
    _sortDirection = widget.smart.sortDirection;
    _limitController =
        TextEditingController(text: widget.smart.limit?.toString() ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _limitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffold(context),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('编辑智能歌单',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.onScaffold(context))),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _card(
              child: TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '歌单名称',
                  hintText: '例如：最近常听的摇滚',
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildSortCard(),
            const SizedBox(height: 12),
            _buildGroupCombinatorCard(),
            const SizedBox(height: 12),
            for (var i = 0; i < _groups.length; i++) ...[
              _buildGroupCard(i),
              const SizedBox(height: 12),
            ],
            TextButton.icon(
              onPressed: () =>
                  setState(() => _groups.add(const SmartPlaylistRuleGroup())),
              icon: const Icon(Icons.add),
              label: const Text('添加规则组'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder(context)),
      ),
      child: child,
    );
  }

  Widget _buildSortCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('排序',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onScaffold(context))),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<SmartPlaylistSortField>(
                  initialValue: _sortField,
                  decoration: const InputDecoration(
                      isDense: true, labelText: '排序字段'),
                  items: [
                    for (final f in SmartPlaylistSortField.values)
                      DropdownMenuItem(value: f, child: Text(f.label)),
                  ],
                  onChanged: (v) => setState(() => _sortField = v!),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<SmartPlaylistSortDirection>(
                  initialValue: _sortDirection,
                  decoration: const InputDecoration(
                      isDense: true, labelText: '方向'),
                  items: [
                    for (final d in SmartPlaylistSortDirection.values)
                      DropdownMenuItem(value: d, child: Text(d.label)),
                  ],
                  onChanged: (v) => setState(() => _sortDirection = v!),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _limitController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      isDense: true, labelText: '数量上限'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCombinatorCard() {
    return _card(
      child: Row(
        children: [
          Text('规则组间关系',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onScaffold(context))),
          const Spacer(),
          SegmentedButton<SmartPlaylistCombinator>(
            segments: const [
              ButtonSegment(
                value: SmartPlaylistCombinator.and,
                label: Text('全部满足 (且)'),
              ),
              ButtonSegment(
                value: SmartPlaylistCombinator.or,
                label: Text('任一满足 (或)'),
              ),
            ],
            selected: {_groupCombinator},
            onSelectionChanged: (s) =>
                setState(() => _groupCombinator = s.first),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard(int groupIndex) {
    final group = _groups[groupIndex];
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('规则组 ${groupIndex + 1}',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.onScaffold(context))),
              const Spacer(),
              SegmentedButton<SmartPlaylistCombinator>(
                segments: const [
                  ButtonSegment(value: SmartPlaylistCombinator.and, label: Text('且')),
                  ButtonSegment(value: SmartPlaylistCombinator.or, label: Text('或')),
                ],
                selected: {group.combinator},
                style: const ButtonStyle(
                    visualDensity: VisualDensity.compact),
                onSelectionChanged: (s) => setState(() {
                  _groups[groupIndex] = SmartPlaylistRuleGroup(
                    combinator: s.first,
                    rules: group.rules,
                    isExcluded: group.isExcluded,
                  );
                }),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: () => setState(() {
                  _groups[groupIndex] = SmartPlaylistRuleGroup(
                    combinator: group.combinator,
                    rules: group.rules,
                    isExcluded: !group.isExcluded,
                  );
                }),
                child: Text(group.isExcluded ? '排除' : '包含'),
              ),
              if (_groups.length > 1)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () =>
                      setState(() => _groups.removeAt(groupIndex)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (var r = 0; r < group.rules.length; r++) _buildRule(groupIndex, r),
          TextButton.icon(
            onPressed: () => setState(() {
              final rules = [...group.rules];
              rules.add(SmartPlaylistRule(
                field: SmartPlaylistField.title,
                op: SmartPlaylistOp.contains,
                value: '',
              ));
              _groups[groupIndex] = SmartPlaylistRuleGroup(
                combinator: group.combinator,
                rules: rules,
                isExcluded: group.isExcluded,
              );
            }),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加规则'),
          ),
        ],
      ),
    );
  }

  Widget _buildRule(int groupIndex, int ruleIndex) {
    final group = _groups[groupIndex];
    final rule = group.rules[ruleIndex];

    void update(SmartPlaylistRule next) {
      setState(() {
        final rules = [...group.rules];
        rules[ruleIndex] = next;
        _groups[groupIndex] = SmartPlaylistRuleGroup(
          combinator: group.combinator,
          rules: rules,
          isExcluded: group.isExcluded,
        );
      });
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<SmartPlaylistField>(
              initialValue: rule.field,
              isDense: true,
              items: [
                for (final f in SmartPlaylistField.values)
                  DropdownMenuItem(value: f, child: Text(f.label)),
              ],
              onChanged: (v) => update(
                  SmartPlaylistRule(field: v!, op: rule.op, value: rule.value)),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<SmartPlaylistOp>(
              initialValue: rule.op,
              isDense: true,
              items: [
                for (final o in SmartPlaylistOp.values)
                  DropdownMenuItem(value: o, child: Text(o.label)),
              ],
              onChanged: (v) => update(SmartPlaylistRule(
                  field: rule.field, op: v!, value: rule.value)),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 4,
            child: TextFormField(
              initialValue: rule.value,
              decoration: const InputDecoration(isDense: true),
              onChanged: (v) => update(SmartPlaylistRule(
                  field: rule.field, op: rule.op, value: v)),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 18),
            onPressed: () => setState(() {
              final rules = [...group.rules]..removeAt(ruleIndex);
              _groups[groupIndex] = SmartPlaylistRuleGroup(
                combinator: group.combinator,
                rules: rules,
                isExcluded: group.isExcluded,
              );
            }),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入歌单名称')));
      return;
    }
    final limit = int.tryParse(_limitController.text.trim());
    final updated = SmartPlaylist(
      id: widget.smart.id,
      name: name,
      groupCombinator: _groupCombinator,
      groups: _groups
          .where((g) => g.rules.isNotEmpty)
          .map((g) => SmartPlaylistRuleGroup(
                combinator: g.combinator,
                rules: g.rules,
                isExcluded: g.isExcluded,
              ))
          .toList(),
      sortField: _sortField,
      sortDirection: _sortDirection,
      limit: limit,
      createdAt: widget.smart.createdAt,
      updatedAt: DateTime.now(),
    );
    await ref
        .read(smartPlaylistControllerProvider.notifier)
        .update(updated);
    if (mounted) Navigator.pop(context);
  }
}
