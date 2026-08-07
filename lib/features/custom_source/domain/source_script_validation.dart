class SourceScriptHeader {
  const SourceScriptHeader(this.values);

  final Map<String, String> values;

  String? operator [](String key) => values[key.toLowerCase()];
}

SourceScriptHeader? parseSourceScriptHeader(String script) {
  final trimmed = script.trimLeft();
  if (!trimmed.startsWith('/*')) return null;
  final end = trimmed.indexOf('*/', 2);
  if (end < 0) return null;
  final header = trimmed.substring(0, end + 2);
  final values = <String, String>{};
  for (final line in header.split('\n')) {
    final match = RegExp(
      r'@([A-Za-z][\w-]*)\s+(.+?)(?:\s*\*/)?$',
    ).firstMatch(line);
    if (match != null) {
      values[match.group(1)!.toLowerCase()] = match.group(2)!.trim();
    }
  }
  return SourceScriptHeader(values);
}

bool isValidSourceScript(String script) {
  final header = parseSourceScriptHeader(script);
  return header != null && (header['name']?.isNotEmpty ?? false);
}
