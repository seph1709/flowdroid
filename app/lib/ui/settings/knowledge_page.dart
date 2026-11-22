import 'package:material_ui/material_ui.dart';

import '../../core/json.dart';
import '../../runtime/knowledge_base.dart';
import '../icons.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';

/// The knowledge bases on this phone: what's in them, a quick search, and deleting.
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key});

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  late Future<List<JsonMap>> _list = ServicesScope.of(context).knowledge.collections();

  void _reload() => setState(() => _list = ServicesScope.of(context).knowledge.collections());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: FutureBuilder<List<JsonMap>>(
        future: _list,
        builder: (context, snap) {
          final list = snap.data;
          return ListView(
            padding: const EdgeInsets.only(bottom: Space.xxl),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.xs),
                child: Text('Knowledge bases', style: theme.textTheme.headlineMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.lg),
                child: Text(
                  'Notes, documents and pages your workflows can search (RAG). '
                  'Add to them with “Add to Knowledge Base”; ask them with “Search Knowledge Base” and an AI step.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (list == null)
                const Padding(
                  padding: EdgeInsets.all(Space.xxl),
                  child: Center(child: QuietSpinner()),
                )
              else if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Space.page),
                  child: Column(
                    children: [
                      const IconTile(icon: AppIcons.database, color: Colors.transparent, size: 56),
                      const SizedBox(height: Space.md),
                      Text('No knowledge bases yet', style: theme.textTheme.titleSmall),
                      const SizedBox(height: Space.xs),
                      Text(
                        'Try the “Save shared text to my notes” template, then “Ask my notes”.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              else
                GroupedSection(
                  children: [
                    for (final kb in list)
                      ListTile(
                        leading: Icon(AppIcons.database, color: c.textSecondary),
                        title: Text(asString(kb['name'])),
                        subtitle: Text(
                          'By ${kb['searchBy']} · ${kb['sources']} sources · ${kb['chunks']} chunks · ${kb['sizeKb']} KB',
                        ),
                        trailing: Icon(AppIcons.chevronRight, color: c.textTertiary),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute<void>(builder: (_) => _KnowledgeDetailPage(name: asString(kb['name']))),
                          );
                          _reload();
                        },
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _KnowledgeDetailPage extends StatefulWidget {
  const _KnowledgeDetailPage({required this.name});

  final String name;

  @override
  State<_KnowledgeDetailPage> createState() => _KnowledgeDetailPageState();
}

class _KnowledgeDetailPageState extends State<_KnowledgeDetailPage> {
  late KnowledgeBase _kb = ServicesScope.of(context).knowledge;
  late Future<List<JsonMap>> _sources = _kb.sources(widget.name);
  final _query = TextEditingController();
  List<JsonMap>? _matches;
  String? _error;
  bool _searching = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _kb = ServicesScope.of(context).knowledge;
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final r = await _kb.call({
      'op': 'search',
      'collection': widget.name,
      'queries': [
        {'query': q, 'topK': 5, 'minScore': 0},
      ],
    });
    if (!mounted) return;
    setState(() {
      _searching = false;
      _error = r['error'] as String?;
      _matches = _error != null ? null : asMapList(asMap(asList(r['results']).firstOrNull)['matches']);
    });
  }

  Future<void> _deleteSource(String source) async {
    await _kb.deleteSource(widget.name, source);
    setState(() => _sources = _kb.sources(widget.name));
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete “${widget.name}”?'),
        content: const Text('Everything saved in this knowledge base is removed from the phone. This can’t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.of(context).danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _kb.clear(widget.name);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(tooltip: 'Delete knowledge base', icon: const Icon(AppIcons.delete), onPressed: _deleteAll),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.lg),
            child: Text(widget.name, style: theme.textTheme.headlineMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Try a question',
                prefixIcon: const Icon(AppIcons.search),
                suffixIcon: _searching
                    ? const Padding(padding: EdgeInsets.all(12), child: QuietSpinner(size: 18))
                    : IconButton(icon: const Icon(AppIcons.forward), onPressed: _search),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, Space.sm, Space.page, 0),
              child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: c.danger)),
            ),
          if (_matches case final matches?) ...[
            SectionLabel(matches.isEmpty ? 'NOTHING MATCHES' : 'BEST MATCHES'),
            for (final m in matches)
              Container(
                margin: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(color: c.grouped, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            asString(m['source']),
                            style: theme.textTheme.labelMedium?.copyWith(color: c.text),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${(asDouble(m['score']) * 100).round()}%',
                          style: theme.textTheme.labelMedium?.copyWith(color: c.accent),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.xs),
                    Text(
                      asString(m['text']),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
          const SectionLabel('SOURCES'),
          FutureBuilder<List<JsonMap>>(
            future: _sources,
            builder: (context, snap) {
              final list = snap.data;
              if (list == null) return const Center(child: QuietSpinner());
              if (list.isEmpty) {
                return const Padding(padding: EdgeInsets.all(Space.page), child: Text('Empty'));
              }
              return GroupedSection(
                children: [
                  for (final s in list)
                    ListTile(
                      title: Text(asString(s['source']), maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${s['chunks']} ${s['chunks'] == 1 ? 'chunk' : 'chunks'} · ${s['characters']} characters',
                      ),
                      trailing: IconButton(
                        tooltip: 'Delete this source',
                        icon: const Icon(AppIcons.delete),
                        onPressed: () => _deleteSource(asString(s['source'])),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
