import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'alarm_system.dart';

// ================================================================
// alarm_alert_overlay.dart
//
// A full-screen pulsing overlay that appears INSIDE the app when
// an alarm is triggered. Shows:
//  - Which sensor triggered (door / motion / remote)
//  - Sensor name and zone
//  - Arm / Disarm action buttons
//  - Dismiss button (if already disarmed externally)
// ================================================================

class AlarmAlertOverlay extends StatefulWidget {
  final String sensorType;
  final String sensorName;
  final String? zoneName;
  final VoidCallback onDisarm;
  final VoidCallback onDismiss;

  const AlarmAlertOverlay({
    Key? key,
    required this.sensorType,
    required this.sensorName,
    this.zoneName,
    required this.onDisarm,
    required this.onDismiss,
  }) : super(key: key);

  @override
  State<AlarmAlertOverlay> createState() => _AlarmAlertOverlayState();
}

class _AlarmAlertOverlayState extends State<AlarmAlertOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;
  Timer? _vibTimer;

  @override
  void initState() {
    super.initState();

    // Pulsing red background
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Repeating vibration every 1.5 s while overlay is visible
    _vibTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      HapticFeedback.heavyImpact();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _vibTimer?.cancel();
    super.dispose();
  }

  String get _sensorIcon {
    switch (widget.sensorType.toLowerCase()) {
      case 'door':   return '🚪';
      case 'window': return '🪟';
      case 'motion': return '👁️';
      case 'remote': return '📡';
      case 'camera': return '📷';
      default:       return '⚠️';
    }
  }

  String get _sensorLabel {
    switch (widget.sensorType.toLowerCase()) {
      case 'door':   return 'Door Sensor';
      case 'window': return 'Window Sensor';
      case 'motion': return 'Motion Sensor';
      case 'remote': return 'Remote Trigger';
      case 'camera': return 'Camera Alert';
      default:       return 'Sensor Alert';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (context, child) {
        return Container(
          color: Color.fromRGBO(
              180, 0, 0, _pulseAnim.value),   // pulsing dark red
          child: child,
        );
      },
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ── Top: Flashing icon ───────────────────────────
            const SizedBox(height: 24),
            Text(
              _sensorIcon,
              style: const TextStyle(fontSize: 80),
            ),
            const SizedBox(height: 16),

            // ── Title ────────────────────────────────────────
            const Text(
              '⚠️  ALARM TRIGGERED',
              style: TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),

            // ── Sensor type badge ─────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white54),
              ),
              child: Text(
                _sensorLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── Sensor name + zone card ───────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white30),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.sensors,
                            color: Colors.white70, size: 20),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            widget.sensorName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                    if (widget.zoneName != null &&
                        widget.zoneName!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.location_on,
                              color: Colors.white54, size: 16),
                          const SizedBox(width: 4),
                          Text(
                            widget.zoneName!,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 36),

            // ── Action buttons ────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                children: [
                  // DISARM button
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        HapticFeedback.heavyImpact();
                        widget.onDisarm();
                      },
                      icon: const Icon(Icons.lock_open, size: 22),
                      label: const Text('DISARM',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 6,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // DISMISS button
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        widget.onDismiss();
                      },
                      icon: const Icon(Icons.close, size: 22),
                      label: const Text('DISMISS',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(
                            color: Colors.white54, width: 2),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Hint text ─────────────────────────────────────
            const Text(
              'Tap DISARM to stop the alarm\nor DISMISS to close this alert',
              style: TextStyle(color: Colors.white54, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// AlarmAlertManager  — wraps your existing screen with the overlay
//
// Usage in home_screen.dart:
//
//   Consumer<AlarmSystemProvider>(
//     builder: (ctx, provider, _) {
//       return AlarmAlertManager(
//         provider: provider,
//         child: YourHomeScreenWidget(),
//       );
//     },
//   )
// ================================================================
class AlarmAlertManager extends StatefulWidget {
  final AlarmSystemProvider provider;
  final Widget child;

  const AlarmAlertManager({
    Key? key,
    required this.provider,
    required this.child,
  }) : super(key: key);

  @override
  State<AlarmAlertManager> createState() => _AlarmAlertManagerState();
}

class _AlarmAlertManagerState extends State<AlarmAlertManager> {
  bool _overlayVisible = false;
  String _sensorType   = 'sensor';
  String _sensorName   = 'Sensor';
  String _zoneName     = '';

  @override
  void initState() {
    super.initState();
    widget.provider.addListener(_onProviderChange);
  }

  @override
  void didUpdateWidget(AlarmAlertManager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      oldWidget.provider.removeListener(_onProviderChange);
      widget.provider.addListener(_onProviderChange);
    }
  }

  void _onProviderChange() {
    final provider = widget.provider;
    if (provider.currentState == SystemState.alarm && !_overlayVisible) {
      // Pull latest trigger info from activity log if available
      final logs = provider.activityLogs;
      if (logs.isNotEmpty) {
        final latestLog = logs.first;
        // Parse sensor info from log device field
        _sensorName = latestLog.device;
        _sensorType = _guessSensorType(latestLog.device);
        _zoneName   = '';
      }
      setState(() => _overlayVisible = true);
    } else if (provider.currentState != SystemState.alarm && _overlayVisible) {
      setState(() => _overlayVisible = false);
    }
  }

  String _guessSensorType(String deviceName) {
    final d = deviceName.toLowerCase();
    if (d.contains('door'))   return 'door';
    if (d.contains('window')) return 'window';
    if (d.contains('motion')) return 'motion';
    if (d.contains('remote')) return 'remote';
    return 'sensor';
  }

  @override
  void dispose() {
    widget.provider.removeListener(_onProviderChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_overlayVisible)
          Positioned.fill(
            child: AlarmAlertOverlay(
              sensorType: _sensorType,
              sensorName: _sensorName,
              zoneName:   _zoneName.isNotEmpty ? _zoneName : null,
              onDisarm: () {
                widget.provider.changeSystemState(SystemState.disarmed);
                setState(() => _overlayVisible = false);
              },
              onDismiss: () {
                setState(() => _overlayVisible = false);
              },
            ),
          ),
      ],
    );
  }
}