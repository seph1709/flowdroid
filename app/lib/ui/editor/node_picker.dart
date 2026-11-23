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
                  _GroupHeader(group),
                  for (final t in types)
                    ListTile(
                      leading: GlyphIcon.forType(type: t.type, group: t.group, size: 30),
                      minLeadingWidth: 30,
                      horizontalTitleGap: Space.lg,
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

/// A group's name over its steps, after a dot in the group's color.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.group);

  final NodeGroup group;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.page, Space.xl, Space.page, Space.xs),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c.groupColor(group), shape: BoxShape.circle),
          ),
          const SizedBox(width: Space.sm),
          Text(NodeVisuals.groupLabel(group).toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
