import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phone_bridge/phone_bridge.dart';

import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import '../icons.dart';

/// Permissions the phone triggers need: SMS, notification access, and location all the time.
class PhoneAccessSection extends StatefulWidget {
  const PhoneAccessSection({super.key});

  @override
  State<PhoneAccessSection> createState() => _PhoneAccessSectionState();
}

class _PhoneAccessSectionState extends State<PhoneAccessSection> with WidgetsBindingObserver {
  PhoneAccess? _access;
  LocationPermission? _location;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final phone = ServicesScope.of(context).phone;
    final access = await phone.access();
    final location = await Geolocator.checkPermission();
    if (mounted) {
      setState(() {
        _access = access;
        _location = location;
      });
    }
  }

  Future<void> _allowLocation() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    // "All the time" can only be chosen in Android's settings.
    if (permission != LocationPermission.always) await Geolocator.openAppSettings();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final phone = ServicesScope.of(context).phone;
    final access = _access;
    Widget row(IconData icon, String title, String subtitle, bool ok, VoidCallback onFix, {String fix = 'Allow'}) =>
        ListTile(
          leading: Icon(icon, color: ok ? c.success : c.textSecondary),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: ok ? null : TextButton(onPressed: onFix, child: Text(fix)),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('PHONE ACCESS'),
        GroupedSection(
          children: [
            row(
              AppIcons.message,
              'SMS',
              access?.sms ?? false ? 'SMS Trigger and Send SMS can work' : 'For the SMS Trigger and Send SMS',
              access?.sms ?? false,
              () async {
                await phone.requestSms();
                await Future<void>.delayed(const Duration(milliseconds: 800));
                await _refresh();
              },
            ),
            row(
              AppIcons.bellDot,
              'Notification access',
              access?.notificationAccess ?? false
                  ? 'The Notification Trigger sees other apps’ notifications'
                  : 'For the Notification Trigger',
              access?.notificationAccess ?? false,
              phone.openNotificationAccess,
              fix: 'Open',
            ),
            row(
              AppIcons.place,
              'Location all the time',
              _location == LocationPermission.always
                  ? 'The Place Trigger can check where you are'
                  : 'For the Place Trigger',
              _location == LocationPermission.always,
              _allowLocation,
            ),
          ],
        ),
      ],
    );
  }
}
