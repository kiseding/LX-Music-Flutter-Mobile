/// Enforces HTTPS for dynamically constructed outbound HTTP URLs.
String normalizeOutboundUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri?.scheme == 'http' && uri!.host.isNotEmpty) {
    return uri.replace(scheme: 'https').toString();
  }
  return value;
}
