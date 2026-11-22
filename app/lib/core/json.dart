/// Small helpers for reading untyped JSON safely.
library;

typedef JsonMap = Map<String, Object?>;

JsonMap asMap(Object? v) => v is Map ? v.cast<String, Object?>() : <String, Object?>{};

List<Object?> asList(Object? v) => v is List ? v.cast<Object?>() : const <Object?>[];

List<JsonMap> asMapList(Object? v) => asList(v).whereType<Map<Object?, Object?>>().map(asMap).toList();

String asString(Object? v, [String fallback = '']) => v is String ? v : fallback;

double asDouble(Object? v, [double fallback = 0]) => v is num ? v.toDouble() : fallback;

int asInt(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;

bool asBool(Object? v, [bool fallback = false]) => v is bool ? v : fallback;
