/// Rejects deterministic synchronous loops that grow the collection used as
/// their own loop bound. Dart timeouts cannot interrupt these loops, so they
/// can terminate the process through JavaScriptCore OOM.
bool hasUnsafeSynchronousLoop(String script) {
  final compact = script.replaceAll(RegExp(r'\s+'), '');
  final code = _withoutCommentsAndStrings(
    script,
  ).replaceAll(RegExp(r'\s+'), '');
  if (RegExp(r'while\(true\)\{').hasMatch(code) ||
      RegExp(r'for\(;;\)\{').hasMatch(code) ||
      RegExp(r'do\{[^{}]{0,400}\}while\(true\)').hasMatch(code)) {
    return true;
  }
  final recursive = RegExp(
    r'(?:function([\w$]+)|([\w$]+)=function)\([^)]*\)\{([^{}]{0,1600})\}',
  );
  for (final match in recursive.allMatches(code)) {
    final name = match.group(1) ?? match.group(2);
    final body = match.group(3)!;
    if (name != null &&
        RegExp('${RegExp.escape(name)}\\(').hasMatch(body) &&
        !body.contains('if(') &&
        !RegExp(r'\b(?:while|for)\(').hasMatch(body)) {
      return true;
    }
  }
  final arrowRecursive = RegExp(
    r'(?:const|let|var)([\w$]+)=\([^)]*\)=>(?:\{)?([^{};]{0,800})',
  );
  for (final match in arrowRecursive.allMatches(code)) {
    if (RegExp(
      '${RegExp.escape(match.group(1)!)}\\(',
    ).hasMatch(match.group(2)!)) {
      return true;
    }
  }
  final loops = RegExp(
    r'for\([^;]*;([\w$]+)<([\w$]+);[^)]*\)\{([^{}]{0,1200})\}',
  );
  for (final match in loops.allMatches(compact)) {
    final index = match.group(1)!;
    final bound = match.group(2)!;
    final body = match.group(3)!;
    if (!body.contains('$index++') && !body.contains('$index+=1')) continue;

    final push = RegExp(r'([\w$]+)\.(?:push|unshift)\(').firstMatch(body);
    if (push == null) continue;
    final collection = push.group(1)!;
    final resetsBound = RegExp(
      '${RegExp.escape(bound)}=${RegExp.escape(collection)}\\.length',
    ).hasMatch(body);
    if (resetsBound) return true;
  }

  // Common anti-tamper variant uses bracket notation after minification.
  final bracketPush =
      compact.contains("['push'](") || compact.contains('["push"](');
  final bracketLength =
      compact.contains("['length']") || compact.contains('["length"]');
  final functionSourceCheck =
      compact.contains("['toString']()") || compact.contains('["toString"]()');
  final rewritesLoopBound = RegExp(
    r'''[\w$]+=(?:this\[['"][\w$]+['"]\]|[\w$]+)\[['"]length['"]\]''',
  ).hasMatch(compact);
  return bracketPush &&
      bracketLength &&
      rewritesLoopBound &&
      functionSourceCheck &&
      compact.contains('newRegExp(') &&
      compact.contains('for(');
}

String _withoutCommentsAndStrings(String source) {
  final output = StringBuffer();
  var quote = 0;
  var lineComment = false;
  var blockComment = false;
  var escaped = false;
  for (var i = 0; i < source.length; i++) {
    final char = source.codeUnitAt(i);
    final next = i + 1 < source.length ? source.codeUnitAt(i + 1) : 0;
    if (lineComment) {
      if (char == 10 || char == 13) {
        lineComment = false;
        output.writeCharCode(char);
      }
      continue;
    }
    if (blockComment) {
      if (char == 42 && next == 47) {
        blockComment = false;
        i++;
      }
      continue;
    }
    if (quote != 0) {
      if (escaped) {
        escaped = false;
      } else if (char == 92) {
        escaped = true;
      } else if (char == quote) {
        quote = 0;
      }
      continue;
    }
    if (char == 47 && next == 47) {
      lineComment = true;
      i++;
    } else if (char == 47 && next == 42) {
      blockComment = true;
      i++;
    } else if (char == 34 || char == 39 || char == 96) {
      quote = char;
    } else {
      output.writeCharCode(char);
    }
  }
  return output.toString();
}
