/// 智能歌单规则字段（基于 MusicItem 可用字段）
enum SmartPlaylistField {
  title('歌名'),
  artist('歌手'),
  album('专辑'),
  platform('平台'),
  duration('时长(秒)'),
  playCount('播放次数'),
  lastPlayedAt('最近播放'),
  isInPlaylist('在某歌单');

  const SmartPlaylistField(this.label);
  final String label;
}

enum SmartPlaylistOp {
  equals('等于'),
  notEquals('不等于'),
  contains('包含'),
  notContains('不包含'),
  greaterThan('大于'),
  lessThan('小于');

  const SmartPlaylistOp(this.label);
  final String label;
}

enum SmartPlaylistCombinator {
  and('且'),
  or('或');

  const SmartPlaylistCombinator(this.label);
  final String label;

  static SmartPlaylistCombinator fromName(String? n) =>
      n == 'or' ? SmartPlaylistCombinator.or : SmartPlaylistCombinator.and;
}

enum SmartPlaylistSortField {
  title('歌名'),
  artist('歌手'),
  album('专辑'),
  duration('时长'),
  playCount('播放次数'),
  lastPlayedAt('最近播放'),
  random('随机');

  const SmartPlaylistSortField(this.label);
  final String label;
}

enum SmartPlaylistSortDirection {
  asc('升序'),
  desc('降序');

  const SmartPlaylistSortDirection(this.label);
  final String label;

  static SmartPlaylistSortDirection fromName(String? n) =>
      n == 'asc' ? SmartPlaylistSortDirection.asc : SmartPlaylistSortDirection.desc;
}

class SmartPlaylistRule {
  const SmartPlaylistRule({
    required this.field,
    required this.op,
    this.value = '',
  });

  final SmartPlaylistField field;
  final SmartPlaylistOp op;
  final String value;

  Map<String, dynamic> toJson() => {
        'field': field.name,
        'op': op.name,
        'value': value,
      };

  static SmartPlaylistRule fromJson(Map<String, dynamic> json) {
    return SmartPlaylistRule(
      field: SmartPlaylistField.values.firstWhere(
        (f) => f.name == json['field'],
        orElse: () => SmartPlaylistField.title,
      ),
      op: SmartPlaylistOp.values.firstWhere(
        (o) => o.name == json['op'],
        orElse: () => SmartPlaylistOp.contains,
      ),
      value: json['value']?.toString() ?? '',
    );
  }
}

class SmartPlaylistRuleGroup {
  const SmartPlaylistRuleGroup({
    this.combinator = SmartPlaylistCombinator.and,
    this.rules = const [],
    this.isExcluded = false,
  });

  final SmartPlaylistCombinator combinator;
  final List<SmartPlaylistRule> rules;
  final bool isExcluded;

  Map<String, dynamic> toJson() => {
        'combinator': combinator.name,
        'rules': rules.map((r) => r.toJson()).toList(),
        'isExcluded': isExcluded,
      };

  static SmartPlaylistRuleGroup fromJson(Map<String, dynamic> json) {
    return SmartPlaylistRuleGroup(
      combinator: SmartPlaylistCombinator.fromName(json['combinator']?.toString()),
      rules: (json['rules'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SmartPlaylistRule.fromJson)
          .toList(),
      isExcluded: json['isExcluded'] == true,
    );
  }
}

class SmartPlaylist {
  const SmartPlaylist({
    required this.id,
    required this.name,
    this.groupCombinator = SmartPlaylistCombinator.and,
    this.groups = const [],
    this.sortField = SmartPlaylistSortField.title,
    this.sortDirection = SmartPlaylistSortDirection.asc,
    this.limit,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final SmartPlaylistCombinator groupCombinator;
  final List<SmartPlaylistRuleGroup> groups;
  final SmartPlaylistSortField sortField;
  final SmartPlaylistSortDirection sortDirection;
  final int? limit;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasRules =>
      groups.any((g) => g.rules.isNotEmpty);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'groupCombinator': groupCombinator.name,
        'groups': groups.map((g) => g.toJson()).toList(),
        'sortField': sortField.name,
        'sortDirection': sortDirection.name,
        'limit': limit,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static SmartPlaylist fromJson(Map<String, dynamic> json) {
    return SmartPlaylist(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未命名',
      groupCombinator: SmartPlaylistCombinator.fromName(
          json['groupCombinator']?.toString()),
      groups: (json['groups'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SmartPlaylistRuleGroup.fromJson)
          .toList(),
      sortField: SmartPlaylistSortField.values.firstWhere(
        (f) => f.name == json['sortField'],
        orElse: () => SmartPlaylistSortField.title,
      ),
      sortDirection:
          SmartPlaylistSortDirection.fromName(json['sortDirection']?.toString()),
      limit: (json['limit'] as num?)?.toInt(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] as num?)?.toInt() ?? 0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['updatedAt'] as num?)?.toInt() ?? 0),
    );
  }
}
