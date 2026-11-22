import 'package:material_ui/material_ui.dart';

import '../../core/node_catalog.dart';
import '../kit/kit.dart';
import '../theme.dart';
import '../icons.dart';

/// Bottom sheet listing node types by group, with search. Pops the chosen [NodeType].
class NodePicker extends StatefulWidget {
  const NodePicker({super.key, required this.catalog, this.triggersOnly = false});

  final List<NodeType> catalog;
  final bool triggersOnly;

  static Future<NodeType?> show(BuildContext context, List<NodeType> catalog, {bool triggersOnly = false}) =>
      showModalBottomSheet<NodeType>(
        context: context,
        isScrollControlled: true,
        builder: (_) => NodePicker(catalog: catalog, triggersOnly: triggersOnly),
      );

  @override
  State<NodePicker> createState() => _NodePickerState();
}

class _NodePickerState extends State<NodePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final matches = widget.catalog.where((t) {
      if (widget.triggersOnly && !t.isTrigger) return false;
      return query.isEmpty || t.label.toLowerCase().contains(query) || t.description.toLowerCase().contains(query);
    });
    final groups = <NodeGroup, List<NodeType>>{};
    for (final t in matches) {
      groups.putIfAbsent(t.group, () => []).add(t);
    }
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
            child: TextField(
              autofocus: false,
              decoration: const InputDecoration(prefixIcon: Icon(AppIcons.search), hintText: 'Search steps'),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              children: [
                for (final MapEntry(key: group, value: types) in groups.entries) ...[
                  SectionLabel(NodeVisuals.groupLabel(group).toUpperCase()),
                  for (final t in types)
                    ListTile(
                      leading: IconTile.forType(type: t.type, group: t.group, size: 36),
                      title: Text(t.label, style: Theme.of(context).textTheme.titleSmall),
                      subtitle: Text(t.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, t),
                    ),
                ],
                if (groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No matching nodes')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
