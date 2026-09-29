import '../config/product_configuration.dart';

enum AppDestination {
  home,
  configs,
  logs,
  settings,
}

List<AppDestination> destinationsFor(ProductConfiguration configuration) =>
    const <AppDestination>[
      AppDestination.home,
      AppDestination.configs,
      AppDestination.logs,
      AppDestination.settings,
    ];
