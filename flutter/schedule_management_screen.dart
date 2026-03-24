import 'package:alarm/alarm_schedule.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'settings_manager.dart';
//import 'schedule_model.dart';

class ScheduleManagementScreen extends StatefulWidget {
  const ScheduleManagementScreen({Key? key}) : super(key: key);

  @override
  _ScheduleManagementScreenState createState() =>
      _ScheduleManagementScreenState();
}

class _ScheduleManagementScreenState extends State<ScheduleManagementScreen> {
  final SettingsManager _settingsManager = SettingsManager();
  List<AlarmSchedule> _schedules = [];
  final _uuid = Uuid();

  @override
  void initState() {
    super.initState();
    _loadSchedules();
  }

  void _loadSchedules() {
    setState(() {
      _schedules = _settingsManager.getSchedules();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF1E1E1E),
      appBar: AppBar(
        title: Text('Alarm Schedules'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.add),
            onPressed: _addNewSchedule,
          ),
        ],
      ),
      body: _schedules.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
        padding: EdgeInsets.all(16),
        itemCount: _schedules.length,
        itemBuilder: (context, index) {
          return _buildScheduleCard(_schedules[index]);
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.schedule,
            size: 80,
            color: Colors.white24,
          ),
          SizedBox(height: 20),
          Text(
            'No Schedules Yet',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 10),
          Text(
            'Tap + to create your first schedule',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 14,
            ),
          ),
          SizedBox(height: 30),
          ElevatedButton.icon(
            onPressed: _addNewSchedule,
            icon: Icon(Icons.add),
            label: Text('Add Schedule'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              padding: EdgeInsets.symmetric(horizontal: 30, vertical: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleCard(AlarmSchedule schedule) {
    final isActive = schedule.isActiveNow();

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive
              ? Colors.green
              : (schedule.isEnabled ? Colors.white24 : Colors.white12),
          width: isActive ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          // Header
          ListTile(
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: isActive
                    ? Colors.green.withOpacity(0.2)
                    : Colors.blue.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isActive ? Icons.alarm_on : Icons.schedule,
                color: isActive ? Colors.green : Colors.blue,
              ),
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    schedule.name,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (isActive)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'ACTIVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 4),
                Text(
                  '${schedule.formattedStartTime} - ${schedule.formattedEndTime}',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  schedule.activeDaysString,
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            trailing: Switch(
              value: schedule.isEnabled,
              onChanged: (value) async {
                await _settingsManager.toggleSchedule(schedule.id);
                _loadSchedules();
              },
              activeColor: Colors.green,
            ),
          ),

          // Actions
          Divider(color: Colors.white12, height: 1),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _editSchedule(schedule),
                  icon: Icon(Icons.edit, size: 18),
                  label: Text('Edit'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.blue,
                  ),
                ),
              ),
              Container(width: 1, height: 40, color: Colors.white12),
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _deleteSchedule(schedule),
                  icon: Icon(Icons.delete, size: 18),
                  label: Text('Delete'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _addNewSchedule() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ScheduleEditorScreen(
          onSave: (schedule) {
            _settingsManager.addSchedule(schedule);
            _loadSchedules();
          },
        ),
      ),
    );
  }

  void _editSchedule(AlarmSchedule schedule) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ScheduleEditorScreen(
          schedule: schedule,
          onSave: (updatedSchedule) {
            _settingsManager.updateSchedule(updatedSchedule);
            _loadSchedules();
          },
        ),
      ),
    );
  }

  void _deleteSchedule(AlarmSchedule schedule) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF2D2D2D),
        title: Text('Delete Schedule?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Are you sure you want to delete "${schedule.name}"?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _settingsManager.deleteSchedule(schedule.id);
              _loadSchedules();
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Delete'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// SCHEDULE EDITOR SCREEN
// ============================================================================

class ScheduleEditorScreen extends StatefulWidget {
  final AlarmSchedule? schedule;
  final Function(AlarmSchedule) onSave;

  const ScheduleEditorScreen({
    Key? key,
    this.schedule,
    required this.onSave,
  }) : super(key: key);

  @override
  _ScheduleEditorScreenState createState() => _ScheduleEditorScreenState();
}

class _ScheduleEditorScreenState extends State<ScheduleEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late Set<int> _selectedDays;

  final List<String> _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    if (widget.schedule != null) {
      _nameController.text = widget.schedule!.name;
      _startTime = widget.schedule!.startTime;
      _endTime = widget.schedule!.endTime;
      _selectedDays = widget.schedule!.activeDays.toSet();
    } else {
      _nameController.text = 'New Schedule';
      _startTime = TimeOfDay(hour: 22, minute: 0); // 10 PM
      _endTime = TimeOfDay(hour: 6, minute: 0); // 6 AM
      _selectedDays = {0, 1, 2, 3, 4, 5, 6}; // All days
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF1E1E1E),
      appBar: AppBar(
        title: Text(widget.schedule == null ? 'New Schedule' : 'Edit Schedule'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: EdgeInsets.all(20),
          children: [
            // Schedule Name
            _buildSectionTitle('Schedule Name'),
            TextFormField(
              controller: _nameController,
              style: TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'e.g., Night Mode, Weekday Schedule',
                hintStyle: TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a name';
                }
                return null;
              },
            ),

            SizedBox(height: 30),

            // Start Time
            _buildSectionTitle('Start Time'),
            _buildTimeSelector(_startTime, 'Start', (time) {
              setState(() => _startTime = time);
            }),

            SizedBox(height: 20),

            // End Time
            _buildSectionTitle('End Time'),
            _buildTimeSelector(_endTime, 'End', (time) {
              setState(() => _endTime = time);
            }),

            SizedBox(height: 30),

            // Active Days
            _buildSectionTitle('Active Days'),
            _buildDaySelector(),

            SizedBox(height: 40),

            // Save Button
            ElevatedButton(
              onPressed: _saveSchedule,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                padding: EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                'Save Schedule',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildTimeSelector(
      TimeOfDay time,
      String label,
      Function(TimeOfDay) onTimeSelected,
      ) {
    return InkWell(
      onTap: () async {
        final selectedTime = await showTimePicker(
          context: context,
          initialTime: time,
          builder: (context, child) {
            return Theme(
              data: ThemeData.dark(),
              child: child!,
            );
          },
        );

        if (selectedTime != null) {
          onTimeSelected(selectedTime);
        }
      },
      child: Container(
        padding: EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          children: [
            Icon(Icons.access_time, color: Colors.blue),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    time.format(context),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.edit, color: Colors.white54, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildDaySelector() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(7, (index) {
              final isSelected = _selectedDays.contains(index);
              return GestureDetector(
                onTap: () {
                  setState(() {
                    if (isSelected) {
                      _selectedDays.remove(index);
                    } else {
                      _selectedDays.add(index);
                    }
                  });
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.blue
                        : Colors.white.withOpacity(0.05),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? Colors.blue : Colors.white24,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      _dayNames[index][0],
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white54,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildQuickSelectButton('All Days', () {
                setState(() => _selectedDays = {0, 1, 2, 3, 4, 5, 6});
              }),
              _buildQuickSelectButton('Weekdays', () {
                setState(() => _selectedDays = {0, 1, 2, 3, 4});
              }),
              _buildQuickSelectButton('Weekends', () {
                setState(() => _selectedDays = {5, 6});
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickSelectButton(String label, VoidCallback onPressed) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.blue,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: Text(label, style: TextStyle(fontSize: 12)),
    );
  }

  void _saveSchedule() {
    if (_formKey.currentState!.validate()) {
      if (_selectedDays.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Please select at least one day'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final schedule = AlarmSchedule(
        id: widget.schedule?.id ?? Uuid().v4(),
        name: _nameController.text,
        startTime: _startTime,
        endTime: _endTime,
        activeDays: _selectedDays.toList()..sort(),
        isEnabled: widget.schedule?.isEnabled ?? true,
      );

      widget.onSave(schedule);
      Navigator.pop(context);
    }
  }
}