import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ================================================================
// realtime_sync_service.dart
//
// FIX (original): Duration(seconds:0) → Duration(seconds:5)
//   Zero-second timer caused infinite tight loop → ANR.
//
// FIX 2 (original): Added _isPolling guard so concurrent HTTP
//   calls never stack.
//
// FIX 3 (THIS VERSION):
//   Polls ?action=system_state (per-device scoped) instead of
//   ?action=get_alarm_status (global last-changed device).
//
//   CRITICAL field-name fix:
//   ┌─────────────────────────┬─────────────────┬──────────────┐
//   │ Field needed            │ system_state    │ get_alarm_   │
//   │                         │ PHP response    │ status resp  │
//   ├─────────────────────────┼─────────────────┼──────────────┤
//   │ current state           │ "state"         │"current_state│
//   │ alarm flag              │ (none)          │"alarm_active"│
//   │ who changed it          │ "updated_by"    │"state_updated│
//   │                         │                 │  _by"        │
//   └─────────────────────────┴─────────────────┴──────────────┘
//
//   The old code read data['current_state'] and data['alarm_active']
//   which do NOT exist in system_state responses.
//   Result: rawState was always '' → always resolved to SyncState.disarmed
//   → armed/stay_arm state changes NEVER fired notifications via Layer 2.
//
//   Fixed reads:
//     data['state']      (system_state key for current state)
//     data['updated_by'] (system_state key for actor)
//   Alarm detection: state == 'alarm' (no separate alarm_active field needed)
// ================================================================

/// Mirrors alarm_system.dart SystemState without importing it
/// (avoids circular dependency).
enum SyncState { disarmed, armed, stayArmed, alarm }

class RealtimeSyncService {
  // ── Singleton ────────────────────────────────────────────────
  static final RealtimeSyncService _instance = RealtimeSyncService._internal();
  factory RealtimeSyncService() => _instance;
  RealtimeSyncService._internal();

  static const String _baseUrl =
      'https://monsow.in/alarm/index.php?action=system_state';

  Timer? _timer;
  SyncState? _lastKnownState;
  String _deviceUuid = '';
  void Function(SyncState newState, bool isExternal, String actor)?
  _onStateChange;
  bool _running = false;

  // ── Guard: skip tick if previous HTTP call is still in-flight ──
  bool _isPolling = false;

  /// Set to true by AlarmSystemProvider immediately before it calls
  /// updateSystemState() so the next poll tick ignores the echo.
  bool suppressNextTick = false;

  // ── Start / restart polling ───────────────────────────────────
  void start({
    required String deviceUuid,
    required void Function(SyncState newState, bool isExternal, String actor)
    onStateChange,
  }) {
    // Already running for same device — just update callback
    if (_running && _deviceUuid == deviceUuid) {
      _onStateChange = onStateChange;
      return;
    }
    stop();
    _deviceUuid = deviceUuid;
    _onStateChange = onStateChange;
    _running = true;
    _lastKnownState = null; // first tick always delivers current state

    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _poll());

    // Fire one immediate poll so the UI updates without waiting 6 s
    _poll();

    debugPrint('🔄 RealtimeSyncService started for $deviceUuid');
  }

  // ── Stop polling ──────────────────────────────────────────────
  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _lastKnownState = null;
    _isPolling = false;
    suppressNextTick = false;
    debugPrint('⏹ RealtimeSyncService stopped');
  }

  // ── Switch to a different device UUID ────────────────────────
  void switchDevice(String newUuid) {
    if (newUuid.isEmpty || newUuid == _deviceUuid) return;
    final cb = _onStateChange;
    if (cb != null) start(deviceUuid: newUuid, onStateChange: cb);
  }

  // ── Core poll ─────────────────────────────────────────────────
  Future<void> _poll() async {
    if (_deviceUuid.isEmpty) return;

    // Skip if a previous HTTP call is still running
    if (_isPolling) return;
    _isPolling = true;

    try {
      final res = await http
          .get(Uri.parse('$_baseUrl&device_uuid=${Uri.encodeComponent(_deviceUuid)}'))
          .timeout(const Duration(seconds: 6));

      if (res.statusCode != 200) return;

      final data = jsonDecode(res.body) as Map<String, dynamic>;

      // ── FIX 3: system_state returns 'state' and 'updated_by' ──
      // The old code read 'current_state' and 'alarm_active' which
      // only exist in get_alarm_status responses, NOT system_state.
      // Reading missing fields → rawState always '' → always disarmed.

      // 'state' is the correct key from system_state PHP endpoint
      final rawState = (data['state'] ?? '').toString().toLowerCase();

      // system_state has no 'alarm_active' flag; infer from rawState
      final alarmActive = rawState == 'alarm';

      // 'updated_by' is the correct actor key from system_state
      final actor = (data['updated_by'] ??
          data['state_updated_by'] ?? // keep fallback for get_alarm_status
          data['actor'] ??
          'another user')
          .toString();

      // ── Parse server state ────────────────────────────────────
      final SyncState serverState;
      if (alarmActive || rawState == 'alarm') {
        serverState = SyncState.alarm;
      } else if (rawState == 'armed' || rawState == 'arm') {
        serverState = SyncState.armed;
      } else if (rawState == 'stay' ||
          rawState == 'stay_arm' ||
          rawState == 'stay_armed' ||
          rawState == 'stayarmed' ||
          rawState == 'stay_arm') {
        serverState = SyncState.stayArmed;
      } else {
        serverState = SyncState.disarmed;
      }

      // ── First tick: deliver without treating as external ──────
      if (_lastKnownState == null) {
        _lastKnownState = serverState;
        _onStateChange?.call(serverState, false, actor);
        return;
      }

      // ── No change ────────────────────────────────────────────
      if (serverState == _lastKnownState) return;

      // ── State changed ─────────────────────────────────────────
      final bool isExternal = !suppressNextTick;
      suppressNextTick = false; // consume flag regardless
      _lastKnownState = serverState;
      _onStateChange?.call(serverState, isExternal, actor);
      debugPrint(

          '🔄 Sync: $_lastKnownState → $serverState  external=$isExternal  actor=$actor');
    } catch (_) {
      // Silent — avoid log spam
    } finally {
      // Always release the guard, even if an exception was thrown
      _isPolling = false;

    }
  }
}
