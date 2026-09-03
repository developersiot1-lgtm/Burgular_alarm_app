import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'api_service.dart';
import 'settings_manager.dart';

class ConnectedDevicesScreen extends StatefulWidget {
  const ConnectedDevicesScreen({Key? key}) : super(key: key);

  @override
  _ConnectedDevicesScreenState createState() => _ConnectedDevicesScreenState();
}

class _ConnectedDevicesScreenState extends State<ConnectedDevicesScreen> {
  List<dynamic> _connectedDevices = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchConnectedDevices();
    });
  }

  Future<void> _fetchConnectedDevices() async {
    final apiService = Provider.of<ApiService>(context, listen: false);
    setState(() => _isLoading = true);
    
    try {
      final deviceUuid = SettingsManager().connectedDeviceUuid;
      final devices = await apiService.getMobileDevices(deviceUuid: deviceUuid);
      setState(() {
        _connectedDevices = devices;
        _isLoading = false;
      });
    } catch (e) {
      print('Failed to fetch devices: $e');
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connected Devices'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchConnectedDevices,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _connectedDevices.isEmpty
              ? const Center(child: Text('No devices connected'))
              : ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: _connectedDevices.length,
                  separatorBuilder: (ctx, i) => const Divider(),
                  itemBuilder: (context, index) {
                    final d = _connectedDevices[index];
                    final isOnline = d['status'] == 'online';
                    
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isOnline ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                        child: Icon(
                          Icons.smartphone,
                          color: isOnline ? Colors.green : Colors.red,
                        ),
                      ),
                      title: Text(d['display_name'] ?? 'Unknown User'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if ((d['email'] ?? '').toString().isNotEmpty)
                            Text(d['email']),
                          if ((d['access_type'] ?? '').toString().isNotEmpty)
                            Text('Access: ${d['access_type']}'),
                          Text('Last active: ${d['last_active_at']}'),
                          Text(d['device_model'] ?? '', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isOnline ? Colors.green : Colors.red,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          d['status'] ?? 'unknown',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    );
                  },
                ),


  );
  }
}
