import 'package:flutter/material.dart';

/// Represents a scheduled time range for alarm activation
class AlarmSchedule {
  String id;
  String name;
  TimeOfDay startTime;
  TimeOfDay endTime;
  List<int> activeDays; // 0 = Monday, 6 = Sunday
  bool isEnabled;

  AlarmSchedule({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.activeDays,
    this.isEnabled = true,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'startTime': '${startTime.hour}:${startTime.minute}',
      'endTime': '${endTime.hour}:${endTime.minute}',
      'activeDays': activeDays,
      'isEnabled': isEnabled,
    };
  }

  factory AlarmSchedule.fromJson(Map<String, dynamic> json) {
    final startParts = (json['startTime'] as String).split(':');
    final endParts = (json['endTime'] as String).split(':');

    return AlarmSchedule(
      id: json['id'],
      name: json['name'],
      startTime: TimeOfDay(
        hour: int.parse(startParts[0]),
        minute: int.parse(startParts[1]),
      ),
      endTime: TimeOfDay(
        hour: int.parse(endParts[0]),
        minute: int.parse(endParts[1]),
      ),
      activeDays: List<int>.from(json['activeDays']),
      isEnabled: json['isEnabled'] ?? true,
    );
  }

  String get formattedStartTime => _formatTime(startTime);
  String get formattedEndTime => _formatTime(endTime);

  String _formatTime(TimeOfDay time) {
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  String get activeDaysString {
    if (activeDays.length == 7) return 'Every day';
    if (activeDays.length == 5 &&
        !activeDays.contains(5) &&
        !activeDays.contains(6)) {
      return 'Weekdays';
    }
    if (activeDays.length == 2 &&
        activeDays.contains(5) &&
        activeDays.contains(6)) {
      return 'Weekends';
    }

    final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return activeDays.map((i) => days[i]).join(', ');
  }

  bool isActiveNow() {
    if (!isEnabled) return false;

    final now = DateTime.now();
    final currentDay = (now.weekday - 1) % 7; // Convert to 0 = Mon, 6 = Sun

    if (!activeDays.contains(currentDay)) return false;

    final currentMinutes = now.hour * 60 + now.minute;
    final startMinutes = startTime.hour * 60 + startTime.minute;
    final endMinutes = endTime.hour * 60 + endTime.minute;

    if (startMinutes < endMinutes) {
      // Same day schedule
      return currentMinutes >= startMinutes && currentMinutes < endMinutes;
    } else {
      // Overnight schedule
      return currentMinutes >= startMinutes || currentMinutes < endMinutes;
    }
  }

  AlarmSchedule copyWith({
    String? id,
    String? name,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    List<int>? activeDays,
    bool? isEnabled,
  }) {
    return AlarmSchedule(
      id: id ?? this.id,
      name: name ?? this.name,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      activeDays: activeDays ?? this.activeDays,
      isEnabled: isEnabled ?? this.isEnabled,
    );
  }
}