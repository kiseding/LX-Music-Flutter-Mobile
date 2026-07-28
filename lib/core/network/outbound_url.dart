/// Enforces HTTPS for dynamically constructed outbound HTTP URLs.
String normalizeOutboundUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri?.scheme == 'http' && uri!.host.isNotEmpty) {
    return uri.replace(scheme: 'https').toString();
  }
  return value;
}

/// Validates a user-configured remote service endpoint under strict ATS.
String validateHttpsServiceUrl(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw ArgumentError.value(
      value,
      'url',
      'Server URL must be an absolute HTTPS URL',
    );
  }
  if (uri.userInfo.isNotEmpty) {
    throw ArgumentError.value(
      value,
      'url',
      'Server URL must not contain credentials',
    );
  }
  if (uri.hasQuery || uri.hasFragment) {
    throw ArgumentError.value(
      value,
      'url',
      'Server URL must not contain a query or fragment',
    );
  }
  final normalizedPath = uri.path.replaceAll(RegExp(r'/+$'), '');
  return uri.replace(path: normalizedPath).toString();
}
