class CustomSource {
  final String id;
  final String name;
  final String description;
  final String version;
  final String author;
  final String? homepage;
  final String script;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isEnabled;

  const CustomSource({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.author,
    this.homepage,
    required this.script,
    required this.createdAt,
    required this.updatedAt,
    this.isEnabled = true,
  });

  CustomSource copyWith({
    String? id,
    String? name,
    String? description,
    String? version,
    String? author,
    String? homepage,
    String? script,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isEnabled,
  }) {
    return CustomSource(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      version: version ?? this.version,
      author: author ?? this.author,
      homepage: homepage ?? this.homepage,
      script: script ?? this.script,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isEnabled: isEnabled ?? this.isEnabled,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'version': version,
      'author': author,
      'homepage': homepage,
      'script': script,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'isEnabled': isEnabled,
    };
  }

  factory CustomSource.fromJson(Map<String, dynamic> json) {
    return CustomSource(
      id: json['id'],
      name: json['name'],
      description: json['description'] ?? '',
      version: json['version'] ?? '1.0.0',
      author: json['author'] ?? '',
      homepage: json['homepage'],
      script: json['script'],
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: DateTime.parse(json['updatedAt']),
      isEnabled: json['isEnabled'] ?? true,
    );
  }
}
