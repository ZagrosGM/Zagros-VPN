import 'tunnel_models.dart';

/// Privileged native tunnel boundary.
///
/// Implementations must consume runtime config directly and must not persist,
/// log, display, or return its secret fields. No implementation may report a
/// connected state until the OS/native engine confirms tunnel establishment.
abstract interface class TunnelAdapter {
  Future<TunnelCapabilities> capabilities();

  Stream<TunnelSnapshot> get snapshots;

  Future<TunnelSnapshot> current();

  Future<TunnelSnapshot> connect(TunnelConnectRequest request);

  Future<TunnelSnapshot> disconnect({required String reason});

  Future<void> dispose();
}
