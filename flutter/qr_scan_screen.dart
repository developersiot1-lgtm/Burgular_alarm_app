import 'package:flutter/material.dart';
//import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'dart:io';
import 'bluetooth_device_picker_screen.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
class QRScanScreen extends StatefulWidget {
  @override
  _QRScanScreenState createState() => _QRScanScreenState();
}

class _QRScanScreenState extends State<QRScanScreen> {
  final MobileScannerController cameraController = MobileScannerController();
  bool isScanned = false;

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Scan QR Code'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: ValueListenableBuilder<TorchState>(
              valueListenable: cameraController.torchState,
              builder: (context, state, child) {
                return Icon(
                  state == TorchState.off ? Icons.flash_off : Icons.flash_on,
                );
              },
            ),
            onPressed: () => cameraController.toggleTorch(),
          ),
          IconButton(
            icon: ValueListenableBuilder<CameraFacing>(
              valueListenable: cameraController.cameraFacingState,
              builder: (context, state, child) {
                return Icon(Icons.camera_rear);
              },
            ),
            onPressed: () => cameraController.switchCamera(),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Stack(
              children: [
                MobileScanner(
                  controller: cameraController,
                  onDetect: _onQRCodeDetected,
                ),
                // Overlay frame
                Center(
                  child: Container(
                    width: 280,
                    height: 280,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.blue,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                // Corner decorations
                Positioned.fill(
                  child: Container(
                    margin: EdgeInsets.all((MediaQuery.of(context).size.width - 280) / 2),
                    child: Stack(
                      children: [
                        // Top-left corner
                        Positioned(
                          top: 0,
                          left: 0,
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(color: Colors.blue, width: 4),
                                left: BorderSide(color: Colors.blue, width: 4),
                              ),
                            ),
                          ),
                        ),
                        // Top-right corner
                        Positioned(
                          top: 0,
                          right: 0,
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(color: Colors.blue, width: 4),
                                right: BorderSide(color: Colors.blue, width: 4),
                              ),
                            ),
                          ),
                        ),
                        // Bottom-left corner
                        Positioned(
                          bottom: 0,
                          left: 0,
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: Colors.blue, width: 4),
                                left: BorderSide(color: Colors.blue, width: 4),
                              ),
                            ),
                          ),
                        ),
                        // Bottom-right corner
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: Colors.blue, width: 4),
                                right: BorderSide(color: Colors.blue, width: 4),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Container(
              padding: EdgeInsets.all(20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.qr_code_scanner,
                      size: 48,
                      color: Colors.blue,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Position the QR code within the frame',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'The camera will automatically scan the code',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onQRCodeDetected(BarcodeCapture barcodeCapture) {
    if (isScanned) return;

    final List<Barcode> barcodes = barcodeCapture.barcodes;
    for (final barcode in barcodes) {
      final String? code = barcode.rawValue;
      if (code != null) {
        setState(() {
          isScanned = true;
        });

        // Stop camera
        cameraController.stop();

        // Show success feedback
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('QR Code scanned successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );

        // Navigate to Bluetooth device picker after short delay
        Future.delayed(Duration(milliseconds: 1500), () {
          if (mounted && !isScanned) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => BluetoothDevicePickerScreen(
                scannedQRCode: code,
              ),
            ),
          );
        });
break;
      }
    }
  }



}
