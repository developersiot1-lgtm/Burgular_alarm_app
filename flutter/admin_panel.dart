import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'bluetooth_device_picker_screen.dart';

class AdminPanel extends StatefulWidget {
  const AdminPanel({super.key});

  @override
  _AdminPanelState createState() => _AdminPanelState();
}

class _AdminPanelState extends State<AdminPanel> {
  final MobileScannerController cameraController = MobileScannerController();

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: MobileScanner(
        controller: cameraController,
        onDetect: (capture) {
          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            final String? code = barcode.rawValue;
            if (code != null) {
              cameraController.stop();

              // Navigate to Bluetooth picker with scanned QR
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (_) => BluetoothDevicePickerScreen(
                    scannedQRCode: code,
                  ),
                ),
              );
              break;
            }
          }
        },
      ),
    );
  }
}
