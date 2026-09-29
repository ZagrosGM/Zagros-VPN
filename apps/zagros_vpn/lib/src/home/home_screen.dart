import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tunnel_interface/tunnel_interface.dart';

import '../../l10n/generated/app_localizations.dart';
import '../account/white_label_controller.dart';
import '../common/formatters.dart';
import '../config/product_configuration.dart';
import '../library/library_controller.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.configuration,
    this.libraryController,
    this.whiteLabelController,
    this.onNavigateToConfigs,
    super.key,
  });

  final ProductConfiguration configuration;
  final LibraryController? libraryController;
  final WhiteLabelController? whiteLabelController;
  final VoidCallback? onNavigateToConfigs;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _speedTimer;
  int _lastTx = 0;
  int _lastRx = 0;
  int _downSpeedBps = 0;
  int _upSpeedBps = 0;
  DateTime _lastSampleTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _startSpeedSampler();
  }

  void _startSpeedSampler() {
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final snapshot = _currentSnapshot();
      final now = DateTime.now();
      final elapsedSec = now.difference(_lastSampleTime).inMilliseconds / 1000.0;
      if (elapsedSec <= 0) return;

      if (snapshot.state == TunnelState.connected) {
        final currentTx = snapshot.uplinkBytes;
        final currentRx = snapshot.downlinkBytes;

        if (_lastTx > 0 && currentTx >= _lastTx) {
          _upSpeedBps = ((currentTx - _lastTx) / elapsedSec).round();
        } else {
          _upSpeedBps = 0;
        }

        if (_lastRx > 0 && currentRx >= _lastRx) {
          _downSpeedBps = ((currentRx - _lastRx) / elapsedSec).round();
        } else {
          _downSpeedBps = 0;
        }

        _lastTx = currentTx;
        _lastRx = currentRx;
      } else {
        _upSpeedBps = 0;
        _downSpeedBps = 0;
        _lastTx = 0;
        _lastRx = 0;
      }

      _lastSampleTime = now;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    super.dispose();
  }

  TunnelSnapshot _currentSnapshot() {
    if (widget.configuration.isWhiteLabel) {
      return widget.whiteLabelController?.tunnelSnapshot ??
          const TunnelSnapshot.disconnected();
    }
    return widget.libraryController?.tunnelSnapshot ??
        const TunnelSnapshot.disconnected();
  }

  bool _isBusy() {
    if (widget.configuration.isWhiteLabel) {
      final ctrl = widget.whiteLabelController;
      return ctrl?.connecting == true || ctrl?.disconnecting == true;
    }
    final ctrl = widget.libraryController;
    return ctrl?.tunnelMutating == true;
  }

  String _activeConfigName(AppLocalizations localizations) {
    if (widget.configuration.isWhiteLabel) {
      final ctrl = widget.whiteLabelController;
      final active = ctrl?.activeSelector;
      if (active != null) {
        return '${active.displayName} (${active.protocol.toUpperCase()})';
      }
      final selected = ctrl?.selectedSelector;
      if (selected != null) {
        return '${selected.displayName} (${selected.protocol.toUpperCase()})';
      }
      return localizations.noActiveConfig;
    }

    final ctrl = widget.libraryController;
    if (ctrl != null) {
      final activeConnId = ctrl.tunnelSnapshot.connectionId;
      if (activeConnId != null) {
        for (final profile in ctrl.catalog.profiles) {
          for (final config in profile.configs) {
            if (config.id == activeConnId) {
              return '${config.normalized.displayName} (${config.normalized.protocol.toUpperCase()})';
            }
          }
        }
      }
      final selected = ctrl.selectedEntry;
      if (selected != null) {
        return '${selected.normalized.displayName} (${selected.normalized.protocol.toUpperCase()})';
      }
    }
    return localizations.noActiveConfig;
  }

  Future<void> _toggleConnection() async {
    final localizations = AppLocalizations.of(context);
    final snapshot = _currentSnapshot();
    if (snapshot.state == TunnelState.connected ||
        snapshot.state == TunnelState.connecting) {
      if (widget.configuration.isWhiteLabel) {
        await widget.whiteLabelController?.disconnect();
      } else {
        await widget.libraryController?.disconnect();
      }
    } else {
      if (widget.configuration.isWhiteLabel) {
        final ctrl = widget.whiteLabelController;
        final target = ctrl?.selectedSelector;
        if (target != null) {
          final res = await ctrl?.connect(target);
          if (mounted &&
              res != WhiteLabelConnectResult.connected &&
              res != WhiteLabelConnectResult.requestAccepted) {
            final msg = ctrl?.lastErrorMessage ??
                ctrl?.protocolUnavailableReason ??
                switch (res) {
                  WhiteLabelConnectResult.protocolUnavailable =>
                    ctrl?.protocolUnavailableReason ?? localizations.tunnelUnavailableBody,
                  WhiteLabelConnectResult.adapterUnavailable =>
                    localizations.tunnelUnavailableBody,
                  _ => localizations.tunnelUnavailableBody,
                };
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(msg)),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(localizations.noActiveConfig),
              action: SnackBarAction(
                label: localizations.configsTitle,
                onPressed: () => widget.onNavigateToConfigs?.call(),
              ),
            ),
          );
          widget.onNavigateToConfigs?.call();
        }
      } else {
        final ctrl = widget.libraryController;
        final target = ctrl?.selectedEntry;
        if (target != null) {
          final res = await ctrl?.connect(target);
          if (mounted &&
              res != OfficialConnectResult.connected &&
              res != OfficialConnectResult.requestAccepted) {
            final msg = ctrl?.lastErrorMessage ??
                ctrl?.protocolUnavailableReason ??
                localizations.tunnelUnavailableBody;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(msg)),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(localizations.noActiveConfig),
              action: SnackBarAction(
                label: localizations.configsTitle,
                onPressed: () => widget.onNavigateToConfigs?.call(),
              ),
            ),
          );
          widget.onNavigateToConfigs?.call();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final ctrl = widget.configuration.isWhiteLabel
        ? widget.whiteLabelController
        : widget.libraryController;

    if (ctrl == null) {
      final snapshot = _currentSnapshot();
      final busy = _isBusy();
      final isConnected = snapshot.state == TunnelState.connected;
      final isConnecting = snapshot.state == TunnelState.connecting;
      final isFailed = snapshot.state == TunnelState.failed;

      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            _buildSubscriptionCard(context, localizations),
            const SizedBox(height: 32),
            _buildConnectButton(context, snapshot, busy, isConnected, isConnecting, isFailed),
            const SizedBox(height: 24),
            _buildStatusText(context, localizations, snapshot),
            const SizedBox(height: 12),
            _buildActiveConfigChip(context, localizations),
            const SizedBox(height: 28),
            _buildSpeedCards(context, localizations),
          ],
        ),
      );
    }

    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        final snapshot = _currentSnapshot();
        final busy = _isBusy();
        final isConnected = snapshot.state == TunnelState.connected;
        final isConnecting = snapshot.state == TunnelState.connecting;
        final isFailed = snapshot.state == TunnelState.failed;

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _buildSubscriptionCard(context, localizations),
              const SizedBox(height: 32),
              _buildConnectButton(context, snapshot, busy, isConnected, isConnecting, isFailed),
              const SizedBox(height: 24),
              _buildStatusText(context, localizations, snapshot),
              const SizedBox(height: 12),
              _buildActiveConfigChip(context, localizations),
              const SizedBox(height: 28),
              _buildSpeedCards(context, localizations),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSubscriptionCard(
    BuildContext context,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);

    // Extract usage info from WhiteLabel or Official profile
    int usedBytes = 0;
    int totalBytes = 0;
    DateTime? expiresAt;

    if (widget.configuration.isWhiteLabel) {
      final usage = widget.whiteLabelController?.usage;
      if (usage != null) {
        usedBytes = usage.usedBytes;
        expiresAt = usage.expiresAt;
      }
    } else {
      final ctrl = widget.libraryController;
      if (ctrl != null && ctrl.catalog.profiles.isNotEmpty) {
        for (final profile in ctrl.catalog.profiles) {
          if (profile.usage != null) {
            usedBytes = profile.usage!.usedBytes;
            totalBytes = profile.usage!.totalBytes;
            expiresAt = profile.usage!.expiresAt;
            break;
          }
        }
      }
    }

    if (totalBytes <= 0 && usedBytes <= 0 && expiresAt == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withAlpha(128),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: theme.colorScheme.outlineVariant.withAlpha(64)),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.shield_outlined, color: theme.colorScheme.primary, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        widget.configuration.appName,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withAlpha(40),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'v1.4.1',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    localizations.foundationTitle,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final fraction = totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
    final percentage = (fraction * 100).toStringAsFixed(0);

    final daysRemaining = expiresAt
        ?.difference(DateTime.now())
        .inDays
        .clamp(0, 9999);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(150),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: theme.colorScheme.primary.withAlpha(40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.pie_chart_outline, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    localizations.usageTitle,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withAlpha(40),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'v1.4.1',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
              if (daysRemaining != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    localizations.subscriptionRemaining(daysRemaining),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 8,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(
                fraction > 0.9 ? theme.colorScheme.error : theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                localizations.subscriptionUsage(
                  formatBytes(usedBytes),
                  totalBytes > 0 ? formatBytes(totalBytes) : localizations.unlimited,
                ),
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
              if (totalBytes > 0)
                Text(
                  '$percentage%',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConnectButton(
    BuildContext context,
    TunnelSnapshot snapshot,
    bool busy,
    bool isConnected,
    bool isConnecting,
    bool isFailed,
  ) {
    final theme = Theme.of(context);

    Color buttonColor;
    Color iconColor;
    Color glowColor;

    if (isConnected) {
      buttonColor = const Color(0xFF00C853);
      iconColor = Colors.white;
      glowColor = const Color(0xFF00C853).withAlpha(80);
    } else if (isConnecting) {
      buttonColor = theme.colorScheme.primary;
      iconColor = Colors.white;
      glowColor = theme.colorScheme.primary.withAlpha(90);
    } else if (isFailed) {
      buttonColor = theme.colorScheme.errorContainer;
      iconColor = theme.colorScheme.onErrorContainer;
      glowColor = theme.colorScheme.error.withAlpha(60);
    } else {
      buttonColor = theme.colorScheme.surfaceContainerHighest;
      iconColor = theme.colorScheme.primary;
      glowColor = Colors.transparent;
    }

    return GestureDetector(
      onTap: busy ? null : _toggleConnection,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 170,
        height: 170,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: buttonColor,
          boxShadow: <BoxShadow>[
            if (isConnected || isConnecting)
              BoxShadow(
                color: glowColor,
                blurRadius: 36,
                spreadRadius: 8,
              ),
          ],
          border: Border.all(
            color: isConnected
                ? Colors.white.withAlpha(200)
                : theme.colorScheme.outlineVariant.withAlpha(100),
            width: 4,
          ),
        ),
        child: Center(
          child: isConnecting || busy
              ? const SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 4,
                  ),
                )
              : Icon(
                  Icons.power_settings_new_rounded,
                  size: 76,
                  color: iconColor,
                ),
        ),
      ),
    );
  }

  Widget _buildStatusText(
    BuildContext context,
    AppLocalizations localizations,
    TunnelSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    final (statusLabel, statusColor) = switch (snapshot.state) {
      TunnelState.connected => (localizations.statusConnected, const Color(0xFF00C853)),
      TunnelState.preparing || TunnelState.connecting => (localizations.statusConnecting, theme.colorScheme.primary),
      TunnelState.disconnecting => (localizations.statusDisconnecting, theme.colorScheme.secondary),
      TunnelState.failed => (localizations.statusFailed, theme.colorScheme.error),
      TunnelState.disconnected => (localizations.statusDisconnected, theme.colorScheme.onSurfaceVariant),
    };

    return Column(
      children: <Widget>[
        Text(
          statusLabel.toUpperCase(),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: statusColor,
          ),
        ),
      ],
    );
  }

  Widget _buildActiveConfigChip(
    BuildContext context,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    final configName = _activeConfigName(localizations);

    return InkWell(
      onTap: widget.onNavigateToConfigs,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.colorScheme.outlineVariant.withAlpha(60)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.dns_outlined, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                configName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedCards(
    BuildContext context,
    AppLocalizations localizations,
  ) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _SpeedCard(
            icon: Icons.arrow_downward_rounded,
            color: const Color(0xFF00E676),
            label: localizations.speedDownload,
            speed: '${formatBytes(_downSpeedBps)}/s',
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _SpeedCard(
            icon: Icons.arrow_upward_rounded,
            color: const Color(0xFF29B6F6),
            label: localizations.speedUpload,
            speed: '${formatBytes(_upSpeedBps)}/s',
          ),
        ),
      ],
    );
  }
}

class _SpeedCard extends StatelessWidget {
  const _SpeedCard({
    required this.icon,
    required this.color,
    required this.label,
    required this.speed,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String speed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(140),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  speed,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
