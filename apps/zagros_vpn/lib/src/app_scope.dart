import 'package:flutter/widgets.dart';

import 'app_dependencies.dart';
import 'config/product_configuration.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    required this.configuration,
    required this.dependencies,
    required super.child,
    super.key,
  });

  final ProductConfiguration configuration;
  final AppDependencies dependencies;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      configuration != oldWidget.configuration ||
      dependencies != oldWidget.dependencies;
}
