import 'package:shared_preferences/shared_preferences.dart';

class NotificationEventDeduper {
  static const String _stateKey = 'last_notified_system_state';
  static const String _timeKey = 'last_notified_system_state_at';
  static const Duration _window = Duration(seconds: 12);

  static Future<bool> claim(String state) async {
    final normalized = state.trim().toLowerCase();
    if (normalized.isEmpty) return false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    final lastState = prefs.getString(_stateKey) ?? '';
    final lastAt = prefs.getInt(_timeKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (lastState == normalized && now - lastAt < _window.inMilliseconds) {
      return false;
    }

    await prefs.setString(_stateKey, normalized);
    await prefs.setInt(_timeKey, now);
    return true;
  }
}
