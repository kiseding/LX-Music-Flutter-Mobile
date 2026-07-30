import 'dart:io';
import 'dart:typed_data';

final class InputLimitException implements Exception {
  const InputLimitException(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() =>
      'InputLimitException($code${message == null ? '' : ': $message'})';
}

final class JsonBudget {
  const JsonBudget({
    this.maximumDepth = 20,
    this.maximumStringLength = 64 * 1024,
    this.maximumCollectionItems = 20000,
  });

  final int maximumDepth;
  final int maximumStringLength;
  final int maximumCollectionItems;
}

Future<Uint8List> readFileBytesBounded(
  File file, {
  required int maximumBytes,
}) async {
  if (maximumBytes < 0) {
    throw ArgumentError.value(maximumBytes, 'maximumBytes');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (builder.length + chunk.length > maximumBytes) {
      throw const InputLimitException('bytes', 'file exceeds maximumBytes');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void validateJsonBudget(Object? value, JsonBudget budget) {
  _validateJsonBudget(value, budget, 0);
}

void _validateJsonBudget(Object? value, JsonBudget budget, int depth) {
  if (depth > budget.maximumDepth) {
    throw const InputLimitException('depth', 'JSON nesting exceeds maximumDepth');
  }
  if (value is String) {
    if (value.length > budget.maximumStringLength) {
      throw const InputLimitException(
        'string',
        'string exceeds maximumStringLength',
      );
    }
    return;
  }
  if (value is List) {
    if (value.length > budget.maximumCollectionItems) {
      throw const InputLimitException(
        'collection',
        'list exceeds maximumCollectionItems',
      );
    }
    for (final item in value) {
      _validateJsonBudget(item, budget, depth + 1);
    }
    return;
  }
  if (value is Map) {
    if (value.length > budget.maximumCollectionItems) {
      throw const InputLimitException(
        'collection',
        'map exceeds maximumCollectionItems',
      );
    }
    for (final entry in value.entries) {
      if (entry.key is String) {
        _validateJsonBudget(entry.key, budget, depth + 1);
      }
      _validateJsonBudget(entry.value, budget, depth + 1);
    }
  }
}
