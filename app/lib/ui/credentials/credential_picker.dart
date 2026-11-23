import 'package:material_ui/material_ui.dart';

import '../../data/credentials.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import 'credential_edit_page.dart';
import '../icons.dart';

/// Picks a saved credential of one of [types] by name, or creates one in place.
class CredentialPicker extends StatelessWidget {
  const CredentialPicker({
    super.key,
    required this.label,
    required this.types,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<String> types;
  final String value;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final store = ServicesScope.of(context).credentials;
    final c = AppColors.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => FutureBuilder<List<Credential>>(
        future: store.all(),
        builder: (context, snapshot) {
          final matching = (snapshot.data ?? const <Credential>[]).where((cr) => types.contains(cr.type)).toList();
          final names = matching.map((cr) => cr.name).toList();
          final missing = value.isNotEmpty && snapshot.hasData && !names.contains(value);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FieldLabel(label),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      key: ValueKey('${names.join(',')}|$value'),
                      initialValue: names.contains(value) ? value : null,
                      hint: Text(matching.isEmpty ? 'None saved yet' : 'Choose…'),
                      items: [
                        for (final cr in matching)
                          DropdownMenuItem(
                            value: cr.name,
                            child: Text(cr.name, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: onChanged,
                      borderRadius: BorderRadius.circular(14),
                      icon: const Icon(AppIcons.chevronDown),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  IconButton.filledTonal(
                    tooltip: 'New credential',
                    icon: const Icon(AppIcons.add),
                    onPressed: () async {
                      final created = await CredentialEditPage.open(context, types: types);
                      if (created != null) onChanged(created.name);
                    },
                  ),
                ],
              ),
              if (missing)
                Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Text(
                    '“$value” is not saved on this phone',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.warning),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
