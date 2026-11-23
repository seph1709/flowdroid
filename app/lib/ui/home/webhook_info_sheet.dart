import 'package:material_ui/material_ui.dart';

import '../../runtime/webhook_server.dart';
import '../services_scope.dart';
import '../theme.dart';

/// Shows where the on-device webhook server listens and how to call it.
class WebhookInfoSheet extends StatelessWidget {
  const WebhookInfoSheet({super.key});

  static Future<void> show(BuildContext context) =>
      showModalBottomSheet<void>(context: context, builder: (_) => const WebhookInfoSheet());

  @override
  Widget build(BuildContext context) {
    final server = ServicesScope.of(context).webhooks;
    final inService = ServicesScope.runtimeOf(context).keepRunning;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: SingleChildScrollView(
          child: FutureBuilder(
            future: server.addresses(),
            builder: (context, snapshot) {
              final addresses = snapshot.data ?? const <String>[];
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Webhook server', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    inService
                        ? 'Listening on port ${WebhookServer.defaultPort} in the background service, even when the app is closed.'
                        : server.isRunning
                        ? 'Listening on port ${WebhookServer.defaultPort} while the app is open. Turn on "Keep running" in Settings to keep it on.'
                        : 'Not running.',
                  ),
                  const SizedBox(height: 16),
                  const Text('Active workflows with a Webhook Trigger answer at:'),
                  const SizedBox(height: 8),
                  for (final a in addresses.isEmpty ? ['http://<phone-ip>:${WebhookServer.defaultPort}'] : addresses)
                    SelectableText('$a/webhook/<path>', style: AppTheme.monospace),
                  const SizedBox(height: 16),
                  const SelectableText(
                    'curl -X POST -H "Content-Type: application/json" \\\n'
                    '  -d \'{"title":"Hi","message":"From my laptop"}\' \\\n'
                    '  http://<phone-ip>:5678/webhook/notify',
                    style: AppTheme.monospace,
                  ),
                  const SizedBox(height: 24),
                  Text('MCP server', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text(
                    'Active workflows with an MCP Tool Trigger are tools for Claude Code and other MCP clients at:',
                  ),
                  const SizedBox(height: 8),
                  for (final a in addresses.isEmpty ? ['http://<phone-ip>:${WebhookServer.defaultPort}'] : addresses)
                    SelectableText('$a${WebhookServer.mcpPath}', style: AppTheme.monospace),
                  const SizedBox(height: 16),
                  SelectableText(
                    'claude mcp add --transport http flowdroid '
                    '${addresses.isEmpty ? 'http://<phone-ip>:${WebhookServer.defaultPort}' : addresses.first}'
                    '${WebhookServer.mcpPath}',
                    style: AppTheme.monospace,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'For a tool that requires a key, add --header "X-FlowDroid-Key: <key>" (or the header its key names).',
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
