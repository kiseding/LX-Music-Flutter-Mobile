import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Returns statically known string values and prefixes from Dart source.
///
/// Unknown interpolation expressions terminate the known prefix. Dynamic URL
/// construction therefore requires runtime scheme enforcement at the outbound
/// request boundary.
List<String> staticallyKnownStrings(String source, {String? path}) {
  final result = parseString(content: source, path: path);
  final constants = <String, String>{};
  final collector = _ConstStringCollector();
  result.unit.accept(collector);
  var changed = true;
  while (changed) {
    changed = false;
    for (final entry in collector.initializers.entries) {
      if (constants.containsKey(entry.key)) continue;
      final value = _evaluateExpression(entry.value, constants);
      if (value != null) {
        constants[entry.key] = value;
        changed = true;
      }
    }
  }
  final visitor = _StaticStringVisitor(constants);
  result.unit.accept(visitor);
  return visitor.values;
}

final class _StaticStringVisitor extends RecursiveAstVisitor<void> {
  _StaticStringVisitor(this.constants);

  final Map<String, String> constants;
  final List<String> values = [];

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    _record(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (node.parent is! StringLiteral) _record(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    if (node.parent is! StringLiteral) _record(node);
  }

  void _record(StringLiteral node) {
    final value = _evaluateString(node, constants);
    if (value != null && value.isNotEmpty) values.add(value);
  }
}

final class _ConstStringCollector extends RecursiveAstVisitor<void> {
  final Map<String, Expression> initializers = {};

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final initializer = node.initializer;
    if (node.isConst && initializer != null) {
      initializers[node.name.lexeme] = initializer;
    }
    super.visitVariableDeclaration(node);
  }
}

String? _evaluateString(StringLiteral node, Map<String, String> constants) {
  return switch (node) {
    SimpleStringLiteral() => node.value,
    AdjacentStrings() =>
      _joinKnown(node.strings.map((part) => _evaluateString(part, constants))),
    StringInterpolation() => _evaluateInterpolation(node, constants),
  };
}

String? _evaluateInterpolation(
  StringInterpolation node,
  Map<String, String> constants,
) {
  final buffer = StringBuffer();
  for (final element in node.elements) {
    switch (element) {
      case InterpolationString():
        buffer.write(element.value);
      case InterpolationExpression():
        final value = _evaluateExpression(element.expression, constants);
        if (value == null) return buffer.isEmpty ? null : buffer.toString();
        buffer.write(value);
    }
  }
  return buffer.toString();
}

String? _evaluateExpression(
  Expression expression,
  Map<String, String> constants,
) {
  return switch (expression) {
    StringLiteral() => _evaluateString(expression, constants),
    SimpleIdentifier() => constants[expression.name],
    IntegerLiteral() => expression.value?.toString(),
    DoubleLiteral() => expression.value.toString(),
    BooleanLiteral() => expression.value.toString(),
    NullLiteral() => 'null',
    ParenthesizedExpression() =>
      _evaluateExpression(expression.expression, constants),
    _ => null,
  };
}

String? _joinKnown(Iterable<String?> parts) {
  final buffer = StringBuffer();
  for (final part in parts) {
    if (part == null) return buffer.isEmpty ? null : buffer.toString();
    buffer.write(part);
  }
  return buffer.toString();
}
