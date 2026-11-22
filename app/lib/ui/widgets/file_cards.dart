import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/json.dart';
import '../../runtime/file_store.dart';
import '../icons.dart';
import '../services_scope.dart';
import '../theme.dart';

/// File references (`{path, name, mimeType, size}`) found at the top level of [items].
List<JsonMap> fileRefsIn(Iterable<JsonMap> items) {
  final seen = <String>{};
  final out = <JsonMap>[];
  void take(Object? v) {
    if (v is Map && v['path'] is String && v['mimeType'] is String && seen.add(v['path']! as String)) {
      out.add(asMap(v));
    }
  }

  for (final item in items) {
    for (final v in item.values) {
      take(v);
      if (v is List) v.forEach(take);
    }
  }
  return out;
}

String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1048576
    ? '${(bytes / 1024).toStringAsFixed(0)} KB'
    : '${(bytes / 1048576).toStringAsFixed(1)} MB';

/// A row of the files in a step's output: preview, name, size; tap opens, Share hands it on.
class FileCards extends StatelessWidget {
  const FileCards(this.refs, {super.key});

  final List<JsonMap> refs;

  @override
  Widget build(BuildContext context) {
    if (refs.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 172,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: refs.length,
        separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
        itemBuilder: (context, i) => _FileCard(refs[i]),
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard(this.ref);

  final JsonMap ref;

  IconData get _icon {
    final mime = asString(ref['mimeType']);
    if (mime == 'application/pdf' || mime.startsWith('text/') || mime.contains('word')) return AppIcons.document;
    if (mime.startsWith('audio/')) return AppIcons.speak;
    if (mime.startsWith('video/')) return AppIcons.playCircle;
    if (mime.contains('json') || mime.contains('xml')) return AppIcons.braces;
    return AppIcons.folder;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final services = ServicesScope.of(context);
    final store = FileStore(services.dataDir);
    final mime = asString(ref['mimeType']);
    File? file;
    try {
      file = store.resolve(asString(ref['path']));
    } on FileStoreException {
      file = null;
    }
    final exists = file?.existsSync() ?? false;
    Future<void> act(Future<String?> Function(String, String) action) async {
      final error = exists ? await action(file!.path, mime) : 'this file is no longer in FlowDroid’s folder';
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      }
    }

    return SizedBox(
      width: 132,
      child: Material(
        color: c.grouped,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => act(services.phone.openFile),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 92,
                child: exists && mime.startsWith('image/') && mime != 'image/heic'
                    ? Image.file(file!, fit: BoxFit.cover, cacheWidth: 300, errorBuilder: (_, _, _) => _iconBox(c))
                    : _iconBox(c),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs + 2, Space.xs, 0),
                child: Text(
                  asString(ref['name'], 'file'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(color: c.text),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: Space.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        exists ? _size(asInt(ref['size'])) : 'missing',
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Share',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(AppIcons.share, size: 16),
                      onPressed: () => act(services.phone.shareFile),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconBox(AppColors c) => ColoredBox(
    color: c.hairline,
    child: Center(child: Icon(_icon, size: 32, color: c.textSecondary)),
  );
}
