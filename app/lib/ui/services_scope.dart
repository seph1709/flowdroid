import 'package:flutter/widgets.dart';

import '../app_services.dart';
import '../runtime/runtime_host.dart';

/// Makes [AppServices] available to every screen.
class ServicesScope extends InheritedWidget {
  const ServicesScope({super.key, required this.services, required this.runtime, required super.child});

  final AppServices services;
  final RuntimeHost runtime;

  static AppServices of(BuildContext context) => _scope(context).services;

  static RuntimeHost runtimeOf(BuildContext context) => _scope(context).runtime;

  static ServicesScope _scope(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ServicesScope>();
    assert(scope != null, 'No ServicesScope above this widget');
    return scope!;
  }

  @override
  bool updateShouldNotify(ServicesScope oldWidget) => services != oldWidget.services || runtime != oldWidget.runtime;
}
