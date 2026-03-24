import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'alarm_system.dart';

/// Widget showing offline status and SOS emergency button
class OfflineSOSWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<AlarmSystemProvider>(
      builder: (context, alarmSystem, child) {
        return Column(
          children: [
            // Offline Status Banner
            if (alarmSystem.isOfflineMode)
              _buildOfflineBanner(context, alarmSystem),

            // Pending Sync Banner
            if (alarmSystem.hasPendingSync)
              _buildPendingSyncBanner(context, alarmSystem),

            SizedBox(height: 16),

            // SOS Emergency Button
            _buildSOSButton(context, alarmSystem),
          ],
        );
      },
    );
  }

  Widget _buildOfflineBanner(BuildContext context, AlarmSystemProvider alarmSystem) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12),
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange, width: 2),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, color: Colors.orange, size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'OFFLINE MODE',
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Alarm system operating locally via Bluetooth',
                  style: TextStyle(
                    color: Colors.orange.withOpacity(0.8),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.bluetooth_connected, color: Colors.orange, size: 20),
        ],
      ),
    );
  }

  Widget _buildPendingSyncBanner(BuildContext context, AlarmSystemProvider alarmSystem) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12),
      margin: EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue),
      ),
      child: Row(
        children: [
          Icon(Icons.sync, color: Colors.blue, size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              '${alarmSystem.pendingActionsCount} actions waiting to sync',
              style: TextStyle(color: Colors.blue, fontSize: 12),
            ),
          ),
          if (!alarmSystem.isOfflineMode)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.blue),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSOSButton(BuildContext context, AlarmSystemProvider alarmSystem) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onLongPress: () => _showSOSConfirmation(context, alarmSystem),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 300),
            width: double.infinity,
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: alarmSystem.isSOSMode
                    ? [Colors.purple.shade700, Colors.purple.shade900]
                    : [Colors.red.shade700, Colors.red.shade900],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: (alarmSystem.isSOSMode ? Colors.purple : Colors.red)
                      .withOpacity(0.3),
                  blurRadius: 12,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              children: [
                Icon(
                  alarmSystem.isSOSMode ? Icons.cancel : Icons.emergency,
                  color: Colors.white,
                  size: 48,
                ),
                SizedBox(height: 12),
                Text(
                  alarmSystem.isSOSMode ? 'SOS ACTIVE' : 'EMERGENCY SOS',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  alarmSystem.isSOSMode
                      ? 'Tap to cancel emergency alarm'
                      : 'Hold 3 seconds to trigger emergency alarm',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      alarmSystem.isOfflineMode
                          ? Icons.bluetooth
                          : Icons.cloud_done,
                      color: Colors.white.withOpacity(0.7),
                      size: 16,
                    ),
                    SizedBox(width: 8),
                    Text(
                      alarmSystem.isOfflineMode
                          ? 'Works Offline via Bluetooth'
                          : 'Connected to Server',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSOSConfirmation(BuildContext context, AlarmSystemProvider alarmSystem) {
    if (alarmSystem.isSOSMode) {
      // If SOS is active, deactivate it
      _deactivateSOS(context, alarmSystem);
      return;
    }

    // Show confirmation dialog
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red.shade900,
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.white, size: 32),
            SizedBox(width: 12),
            Text(
              'EMERGENCY SOS',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will:',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 12),
            _buildSOSFeature('Trigger alarm on all devices'),
            _buildSOSFeature('Sound alarm on this phone'),
            _buildSOSFeature('Work even without internet'),
            _buildSOSFeature('Send alert via Bluetooth'),
            if (!alarmSystem.isOfflineMode)
              _buildSOSFeature('Notify emergency contacts'),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    alarmSystem.isOfflineMode
                        ? Icons.bluetooth
                        : Icons.wifi,
                    color: Colors.white,
                    size: 20,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      alarmSystem.isOfflineMode
                          ? 'Offline mode - using Bluetooth'
                          : 'Online - full functionality available',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.white),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _activateSOS(context, alarmSystem);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.red.shade900,
            ),
            child: Text(
              'TRIGGER SOS',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSOSFeature(String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: Colors.white, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  void _activateSOS(BuildContext context, AlarmSystemProvider alarmSystem) async {
    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Triggering SOS...'),
          ],
        ),
      ),
    );

    // Trigger SOS
    await alarmSystem.triggerSOSAlarm();

    // Close loading dialog
    Navigator.pop(context);

    // Show success
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.warning, color: Colors.white),
            SizedBox(width: 12),
            Text('🚨 SOS ALARM ACTIVATED'),
          ],
        ),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _deactivateSOS(BuildContext context, AlarmSystemProvider alarmSystem) async {
    await alarmSystem.stopSOSAlarm();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ SOS Alarm Stopped'),
        backgroundColor: Colors.green,
      ),
    );
  }
}