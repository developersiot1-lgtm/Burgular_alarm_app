import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../alarm_system.dart';

class DeviceList extends StatelessWidget {
  final List<Device> devices;

  const DeviceList({Key? key, required this.devices}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return Container(
        height: 100,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.device_unknown,
                color: Colors.white54,
                size: 32,
              ),
              SizedBox(height: 8),
              Text(
                'No devices connected',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: NeverScrollableScrollPhysics(),
      itemCount: devices.length,
      separatorBuilder: (context, index) => Divider(
        color: Colors.white24,
        height: 1,
      ),
      itemBuilder: (context, index) {
        final device = devices[index];
        return DeviceCard(device: device);
      },
    );
  }
}

class DeviceCard extends StatelessWidget {
  final Device device;

  const DeviceCard({Key? key, required this.device}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final isOnline = device.status == 'online';
    final lastActivity = DateTime.parse(device.lastActivity);

    return Container(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          // Device Icon
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: isOnline ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isOnline ? Colors.green : Colors.red,
                width: 1,
              ),
            ),
            child: Center(
              child: Text(
                device.typeIcon,
                style: TextStyle(fontSize: 20),
              ),
            ),
          ),
          SizedBox(width: 16),

          // Device Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        device.name,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: isOnline ? Colors.green : Colors.red,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        device.status.toUpperCase(),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.location_on,
                      color: Colors.white70,
                      size: 12,
                    ),
                    SizedBox(width: 4),
                    Text(
                      device.zone,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    SizedBox(width: 16),
                    Icon(
                      Icons.access_time,
                      color: Colors.white70,
                      size: 12,
                    ),
                    SizedBox(width: 4),
                    Text(
                      _formatLastActivity(lastActivity),
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Battery Level
          if (device.battery > 0) ...[
            SizedBox(width: 12),
            Column(
              children: [
                Icon(
                  _getBatteryIcon(device.battery),
                  color: _getBatteryColor(device.battery),
                  size: 20,
                ),
                SizedBox(height: 2),
                Text(
                  '${device.battery}%',
                  style: TextStyle(
                    color: _getBatteryColor(device.battery),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _formatLastActivity(DateTime lastActivity) {
    final now = DateTime.now();
    final difference = now.difference(lastActivity);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h ago';
    } else {
      return DateFormat('MMM dd').format(lastActivity);
    }
  }

  IconData _getBatteryIcon(int battery) {
    if (battery > 75) return Icons.battery_full;
    if (battery > 50) return Icons.battery_5_bar;
    if (battery > 25) return Icons.battery_3_bar;
    if (battery > 10) return Icons.battery_1_bar;
    return Icons.battery_alert;
  }

  Color _getBatteryColor(int battery) {
    if (battery > 50) return Colors.green;
    if (battery > 25) return Colors.orange;
    return Colors.red;
  }
}