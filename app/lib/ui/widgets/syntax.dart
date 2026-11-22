/// Syntax colors and highlighters for JSON, `{{ }}` expressions and code.
library;

import 'package:material_ui/material_ui.dart';

/// Token colors, tuned to the Calm Clarity palette: muted, never neon.
@immutable
class SyntaxColors {
  const SyntaxColors({
    required this.key,
    required this.string,
    required this.number,
    required this.keyword,
    required this.punctuation,
    required this.comment,
    required this.expression,
    required this.expressionBackground,
    required this.match,
  });

  static const light = SyntaxColors(
    key: Color(0xFF3A3A44),
    string: Color(0xFF137A55),
    number: Color(0xFF2A62D4),
    keyword: Color(0xFF8A47CF),
    punctuation: Color(0xFF9A9AA0),
    comment: Color(0xFF9A9AA0),
    expression: Color(0xFF1F5FD0),
    expressionBackground: Color(0xFFEAF1FE),
    match: Color(0x40E8920C),
  );

  static const dark = SyntaxColors(
    key: Color(0xFFDCDCE2),
    string: Color(0xFF6BCB9B),
    number: Color(0xFF86AEFF),
    keyword: Color(0xFFC09BF5),
    punctuation: Color(0xFF6E6E76),
    comment: Color(0xFF6E6E76),
    expression: Color(0xFF9CBDFF),
    expressionBackground: Color(0xFF1B2740),
    match: Color(0x55F2A93B),
  );

  final Color key;
  final Color string;
  final Color number;
  final Color keyword;
  final Color punctuation;
  final Color comment;
  final Color expression;
  final Color expressionBackground;
  final Color match;

  static SyntaxColors of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// Color for a scalar JSON value shown in a tree.
  Color forValue(Object? v) => switch (v) {
    String _ => string,
    num _ => number,
    bool _ || null => keyword,
    _ => key,
  };
}

final _jsonToken = RegExp(
  r'("(?:[^"\\]|\\.)*"?)(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b|([{}\[\],:])',
);

/// JSON (also partial or invalid JSON) as colored spans.
List<TextSpan> jsonSpans(String text, SyntaxColors c) {
  final spans = <TextSpan>[];
  var at = 0;
  for (final m in _jsonToken.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    if (m[1] != null) {
      final isKey = m[2] != null;
      spans.add(
        TextSpan(
          text: m[1],
          style: TextStyle(color: isKey ? c.key : c.string),
        ),
      );
      if (isKey) {
        spans.add(
          TextSpan(
            text: m[2],
            style: TextStyle(color: c.punctuation),
          ),
        );
      }
    } else if (m[3] != null) {
      spans.add(
        TextSpan(
          text: m[3],
          style: TextStyle(color: c.number),
        ),
      );
    } else if (m[4] != null) {
      spans.add(
        TextSpan(
          text: m[4],
          style: TextStyle(color: c.keyword),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: m[5],
          style: TextStyle(color: c.punctuation),
        ),
      );
    }
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return spans;
}

final _template = RegExp(r'\{\{[\s\S]*?(\}\}|$)');
final _exprToken = RegExp(r'''(\$[A-Za-z_]\w*)|("(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?)|(\b\d+(?:\.\d+)?\b)''');

/// Text with `{{ }}` regions marked as expressions; [json] colors the rest as JSON.
List<TextSpan> templateSpans(String text, SyntaxColors c, {bool json = false}) {
  final spans = <TextSpan>[];
  var at = 0;
  void plain(String s) {
    if (s.isEmpty) return;
    if (json) {
      spans.addAll(jsonSpans(s, c));
    } else {
      spans.add(TextSpan(text: s));
    }
  }

  for (final m in _template.allMatches(text)) {
    plain(text.substring(at, m.start));
    spans.add(_expressionSpan(m[0]!, c));
    at = m.end;
  }
  plain(text.substring(at));
  return spans;
}

TextSpan _expressionSpan(String source, SyntaxColors c) {
  final base = TextStyle(color: c.expression, backgroundColor: c.expressionBackground);
  final children = <TextSpan>[];
  var at = 0;
  for (final m in _exprToken.allMatches(source)) {
    if (m.start > at) children.add(TextSpan(text: source.substring(at, m.start)));
    final color = m[1] != null ? c.keyword : (m[2] != null ? c.string : c.number);
    children.add(
      TextSpan(
        text: m[0],
        style: TextStyle(color: color, fontWeight: m[1] != null ? FontWeight.w500 : null),
      ),
    );
    at = m.end;
  }
  if (at < source.length) children.add(TextSpan(text: source.substring(at)));
  return TextSpan(style: base, children: children);
}

const _jsKeywords = {
  'const', 'let', 'var', 'function', 'return', 'if', 'else', 'for', 'while', 'of', 'in', 'new', 'await', //
  'async', 'try', 'catch', 'throw', 'true', 'false', 'null', 'undefined', 'class', 'typeof', 'break', 'continue',
};
const _pyKeywords = {
  'def', 'return', 'if', 'elif', 'else', 'for', 'while', 'in', 'not', 'and', 'or', 'import', 'from', 'as', //
  'try', 'except', 'raise', 'True', 'False', 'None', 'class', 'with', 'lambda', 'pass', 'break', 'continue', 'is',
};

final _jsCode = RegExp(
  r'''(//[^\n]*|/\*[\s\S]*?(?:\*/|$))|("(?:[^"\\\n]|\\.)*"?|'(?:[^'\\\n]|\\.)*'?|`(?:[^`\\]|\\.)*`?)|(\b\d+(?:\.\d+)?\b)|(\b[A-Za-z_$][\w$]*\b)''',
);
final _pyCode = RegExp(
  r'''(#[^\n]*)|("""[\s\S]*?(?:"""|$)|'(?:[^'\\\n]|\\.)*'?|"(?:[^"\\\n]|\\.)*"?)|(\b\d+(?:\.\d+)?\b)|(\b[A-Za-z_]\w*\b)''',
);

/// JavaScript or Python with comments, strings, numbers and keywords colored.
List<TextSpan> codeSpans(String text, SyntaxColors c, {required bool python}) {
  final keywords = python ? _pyKeywords : _jsKeywords;
  final spans = <TextSpan>[];
  var at = 0;
  for (final m in (python ? _pyCode : _jsCode).allMatches(text)) {
    final Color? color;
    if (m[1] != null) {
      color = c.comment;
    } else if (m[2] != null) {
      color = c.string;
    } else if (m[3] != null) {
      color = c.number;
    } else {
      color = keywords.contains(m[4]) ? c.keyword : (m[4] == 'items' || m[4] == 'item' ? c.expression : null);
    }
    if (color == null) continue;
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    spans.add(
      TextSpan(
        text: m[0],
        style: TextStyle(color: color, fontStyle: m[1] != null ? FontStyle.italic : null),
      ),
    );
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return spans;
}

enum SyntaxMode { template, jsonTemplate, javascript, python }

/// A text controller that colors what is typed, as the field shows it.
class HighlightController extends TextEditingController {
  HighlightController({super.text, this.mode = SyntaxMode.template, this.colors = SyntaxColors.light});

  SyntaxMode mode;
  SyntaxColors colors;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    // Keep the keyboard's composing underline intact while a word is being typed.
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final spans = switch (mode) {
      SyntaxMode.template => templateSpans(text, colors),
      SyntaxMode.jsonTemplate => templateSpans(text, colors, json: true),
      SyntaxMode.javascript => codeSpans(text, colors, python: false),
      SyntaxMode.python => codeSpans(text, colors, python: true),
    };
    return TextSpan(style: style, children: spans);
  }
}
