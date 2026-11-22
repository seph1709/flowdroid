import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:material_ui/material_ui.dart';

import '../credentials/credentials_page.dart';
import '../editor/param_editors.dart';
import '../home/webhook_info_sheet.dart';
import '../kit/kit.dart';
import 'background_setup_page.dart';
import 'backup_section.dart';
import 'knowledge_page.dart';
import 'phone_access_section.dart';
import '../theme.dart';
import '../assistant/assistant_settings_page.dart';
import '../services_scope.dart';
import '../terminal/terminal_page.dart';
import '../icons.dart';

/// Background behavior: the keep-alive service and the permissions it needs.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  bool? _batteryUnrestricted;
  NotificationPermission? _notifications;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-reads permissions when the user comes back from a system settings screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    final battery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    final notifications = await FlutterForegroundTask.checkNotificationPermission();
    if (mounted) {
      setState(() {
        _batteryUnrestricted = battery;
        _notifications = notifications;
      });
    }
  }

  Future<void> _setKeepRunning(bool enabled) async {
    setState(() => _busy = true);
    final runtime = ServicesScope.runtimeOf(context);
    if (enabled) {
      // The service's notification needs this permission on Android 13+.
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
    final ok = await runtime.setKeepRunning(enabled);
    if (!mounted) return;
    setState(() => _busy = false);
    await _refreshPermissions();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Android did not allow the background service')));
    } else if (enabled && mounted) {
      // Phone makers' own battery managers need steps Android can't do for us.
      await BackgroundSetupPage.open(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtime = ServicesScope.runtimeOf(context);
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final batteryOk = _batteryUnrestricted ?? false;
    final notificationsOk = _notifications == NotificationPermission.granted;
    return Scaffold(
      appBar: AppBar(),
      body: ListenableBuilder(
        listenable: runtime,
        builder: (context, _) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
              child: Text('Settings', style: theme.textTheme.headlineMedium),
            ),
            const SectionLabel('BACKGROUND'),
            GroupedSection(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.sm, Space.sm),
                  child: SwitchRow(
                    label: 'Keep running',
                    subtitle:
                        'Schedules and webhooks keep working when the app is closed or the phone restarts. '
                        'Android shows a permanent notification while this is on.',
                    value: runtime.keepRunning,
                    onChanged: _busy ? (_) {} : _setKeepRunning,
                  ),
                ),
                ListTile(
                  leading: Icon(
                    batteryOk && notificationsOk ? AppIcons.checkCircle : AppIcons.warning,
                    color: batteryOk && notificationsOk ? c.success : c.warning,
                  ),
                  title: const Text('Background setup'),
                  subtitle: Text(
                    batteryOk && notificationsOk
                        ? 'Battery, alarms and your phone maker’s own settings'
                        : 'Battery or notifications still limit FlowDroid',
                  ),
                  trailing: Icon(AppIcons.chevronRight, color: c.textTertiary),
                  onTap: () => BackgroundSetupPage.open(context),
                ),
              ],
            ),
            const SectionLabel('APPEARANCE'),
            ListenableBuilder(
              listenable: ServicesScope.of(context).appearance,
              builder: (context, _) {
                final appearance = ServicesScope.of(context).appearance;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                  child: PillSwitch<ThemeMode>(
                    value: appearance.mode,
                    options: const [
                      (value: ThemeMode.system, label: 'System', icon: null),
                      (value: ThemeMode.light, label: 'Light', icon: null),
                      (value: ThemeMode.dark, label: 'Dark', icon: null),
                    ],
                    onChanged: appearance.set,
                  ),
                );
              },
            ),
            const SectionLabel('CONNECTIONS'),
            GroupedSection(
              children: [
                ListTile(
                  leading: Icon(AppIcons.sparkle, color: c.textSecondary),
                  title: const Text('Assistant'),
                  subtitle: const Text('The AI that builds and fixes workflows with you'),
                  trailing: Icon(AppIcons.chevronRight, color: c.textTertiary),
                  onTap: () =>
                      Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => const AssistantSettingsPage())),
                ),
                ListTile(
                  leading: Icon(AppIcons.key, color: c.textSecondary),
                  title: const Text('Credentials'),
                  subtitle: const Text('API keys and tokens, stored encrypted'),
                  trailing: Icon(AppIcons.chevronRight, color: c.textTertiary),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CredentialsPage())),
                ),
                ListTile(
                  leading: Icon(AppIcons.database, color: c.textSecondary),
                  title: const Text('Knowledge bases'),
                  subtitle: const Text('What your workflows can search (RAG)'),
                  trailing: Icon(AppIcons.chevronRight, color: c.textTertiary),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const KnowledgePage())),
                ),
                ListTile(
                  leading: Icon(AppIcons.terminal, color: c.textSecondary),
                  title: const Text('Terminal'),
                  subtitle: const Text('Ubuntu and the phone shell, built in'),
                  trailing: Icon(AppIcons.chevronRight, color: c.textTertiary),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TerminalPage())),
                ),
                ListTile(
                  leading: Icon(AppIcons.webhook, color: c.textSecondary),
                  title: const Text('Webhook server'),
                  subtitle: const Text('Address and an example request'),
                  trailing: Icon(AppIcons.chevronRight, color: c.textTertiary),
                  onTap: () => WebhookInfoSheet.show(context),
                ),
              ],
            ),
            const PhoneAccessSection(),
            const BackupSection(),
            const SizedBox(height: Space.xxl),
          ],
        ),
      ),
    );
  }
}
