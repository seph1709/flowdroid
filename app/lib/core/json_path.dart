/// Paths into JSON values, and the expressions that read them.
library;

/// One step of a path: a map key ([String]) or a list index ([int]).
typedef PathSegment = Object;

final _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

/// `$json.user.name`, `$json.tags[0]`, `$json["first name"]`.
String pathExpression(String root, List<PathSegment> path) {
  final out = StringBuffer(root);
  for (final segment in path) {
    if (segment is int) {
      out.write('[$segment]');
    } else if (segment is String && _identifier.hasMatch(segment)) {
      out.write('.$segment');
    } else {
      out.write('["${'$segment'.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"]');
    }
  }
  return '$out';
}

/// `user.name`, `tags[0]`; a stable key for remembering which branches are open.
String pathKey(List<PathSegment> path) => pathExpression('', path);

/// The value at [path] inside [value], or null when it isn't there.
Object? valueAt(Object? value, List<PathSegment> path) {
  var current = value;
  for (final segment in path) {
    if (segment is int && current is List && segment < current.length) {
      current = current[segment];
    } else if (segment is String && current is Map) {
      current = current[segment];
    } else {
      return null;
    }
  }
  return current;
}

/// Every path whose key or scalar value contains [query] (case-insensitive),
/// plus every container on the way to one; used to filter a tree.
Set<String> matchingPaths(Object? value, String query) {
  final q = query.toLowerCase();
  final hits = <String>{};
  bool walk(Object? v, List<PathSegment> path) {
    var found = false;
    if (v is Map) {
      for (final MapEntry(:key, value: child) in v.entries) {
        final childPath = [...path, '$key'];
        final keyHit = '$key'.toLowerCase().contains(q);
        if (walk(child, childPath) || keyHit) {
          hits.add(pathKey(childPath));
          found = true;
        }
      }
    } else if (v is List) {
      for (var i = 0; i < v.length; i++) {
        final childPath = [...path, i];
        if (walk(v[i], childPath)) {
          hits.add(pathKey(childPath));
          found = true;
        }
      }
    } else {
      found = '$v'.toLowerCase().contains(q);
    }
    return found;
  }

  if (q.isNotEmpty && walk(value, const [])) hits.add(pathKey(const []));
  return hits;
}

/// Paths of every container in [value] up to [depth] levels deep (root is depth 0).
Set<String> containerPaths(Object? value, {int depth = 1 << 30}) {
  final out = <String>{};
  void walk(Object? v, List<PathSegment> path, int level) {
    if (level > depth) return;
    if (v is Map) {
      out.add(pathKey(path));
      for (final MapEntry(:key, value: child) in v.entries) {
        walk(child, [...path, '$key'], level + 1);
      }
    } else if (v is List) {
      out.add(pathKey(path));
      for (var i = 0; i < v.length; i++) {
        walk(v[i], [...path, i], level + 1);
      }
    }
  }

  walk(value, const [], 0);
  return out;
}
