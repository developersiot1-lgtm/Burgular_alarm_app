import 'dart:io';
import 'dart:typed_data';
import 'package:alarm/api_service.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';

class VoiceRecordingScreen extends StatefulWidget {
  const VoiceRecordingScreen({Key? key}) : super(key: key);

  @override
  _VoiceRecordingScreenState createState() => _VoiceRecordingScreenState();
}

class _VoiceRecordingScreenState extends State<VoiceRecordingScreen> {
  ApiService? apiService;
  final Record _recorder = Record();
  bool _isRecording = false;
  String? _recordingPath;
  List<Map<String, dynamic>> _voiceRecordings = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    apiService = Provider.of<ApiService>(context, listen: false);
    _loadVoiceRecordings();
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _loadVoiceRecordings() async {
    if (apiService == null) return;
    try {
      final recs = await apiService!.getVoiceRecordings();
      if (mounted) {
        setState(() => _voiceRecordings = List<Map<String, dynamic>>.from(recs));
      }
    } catch (e) {
      print('Load voice recs error: $e');
    }
  }
  Future<void> _startRecording() async {
    // Request permissions
    final micStatus = await Permission.microphone.request();
    final storageStatus = await Permission.storage.request();

    if (!micStatus.isGranted || !storageStatus.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Microphone and storage permissions are required'),
          backgroundColor: Colors.red,
          action: SnackBarAction(
            label: 'Settings',
            textColor: Colors.white,
            onPressed: () => openAppSettings(),
          ),
        ),
      );
      return;
    }

    final dir = await getTemporaryDirectory();
    _recordingPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';

    try {
      // Check if recorder is available
      bool hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        throw Exception('Microphone permission denied');
      }

      await _recorder.start(
        path: _recordingPath!,
        encoder: AudioEncoder.wav,
        bitRate: 64000,
        samplingRate: 8000,
        numChannels: 1,
      );

      setState(() {
        _isRecording = true;
      });

      print('✅ Recording started: $_recordingPath');
    } catch (e) {
      print('❌ Recording error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Recording failed: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    await _recorder.stop();
    setState(() => _isRecording = false);
    if (_recordingPath != null) {
      await _showSaveDialog();
    }
  }

  Future<void> _showSaveDialog() async {
    String name = '';
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Voice Recording'),
        content: TextField(
          decoration: const InputDecoration(labelText: 'Name'),
          onChanged: (val) => name = val,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (name.isNotEmpty) {
                Navigator.pop(ctx);
                await convertAndSave(name);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> convertAndSave(String name) async {
    try {
      if (_recordingPath == null) return;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Processing recording...')),
        );
      }

      final recordedFile = File(_recordingPath!);
      final fileBytes = await recordedFile.readAsBytes();

      // Convert 16-bit to 8-bit unsigned
      final convertedBytes = convertTo8BitUnsigned(fileBytes);
      
      // Create proper WAV file
      final wavFile = createWavFile(convertedBytes);

      // Save to temp file
      final tempDir = await getTemporaryDirectory();
      final outputPath = '${tempDir.path}/alarm_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      final outputFile = File(outputPath);
      await outputFile.writeAsBytes(wavFile);

      // Upload
      if (apiService != null) {
        await apiService!.uploadVoiceRecording(
          name: name,
          filePath: outputPath,
          sampleRate: 8000,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ Saved: $name')),
          );
        }
        _loadVoiceRecordings();
      }

      // Cleanup
      await recordedFile.delete();
      await outputFile.delete();
      
      setState(() {
        _recordingPath = null;
        _isRecording = false;
      });

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Uint8List convertTo8BitUnsigned(Uint8List wavData) {
    const int headerSize = 44;
    if (wavData.length < headerSize) throw Exception('Invalid WAV file');

    int fmtOffset = 12;
    int dataOffset = fmtOffset + 8 + (wavData[fmtOffset + 4] | (wavData[fmtOffset + 5] << 8));
    
    int dataSize = wavData[dataOffset + 4] |
    (wavData[dataOffset + 5] << 8) |
    (wavData[dataOffset + 6] << 16) |
    (wavData[dataOffset + 7] << 24);

    int pcmStart = dataOffset + 8;
    int numSamples = dataSize ~/ 2;
    Uint8List converted = Uint8List(numSamples);

    for (int i = 0; i < numSamples; i++) {
        int idx = pcmStart + (i * 2);
        if (idx + 1 >= wavData.length) break;
        
        int sample16 = wavData[idx] | (wavData[idx + 1] << 8);
        
        if (sample16 > 32767) sample16 -= 65536;
        
        // 16-bit signed to 8-bit unsigned: (sample / 256) + 128
        int sample8 = ((sample16 >> 8) + 128).clamp(0, 255);
        converted[i] = sample8;
    }
    return converted;
  }

  Uint8List createWavFile(Uint8List pcmData) {
    const int sampleRate = 8000;
    const int channels = 1;
    const int bitDepth = 8;
    const int audioFormat = 1; // PCM

    int byteRate = sampleRate * channels * (bitDepth ~/ 8);
    int blockAlign = channels * (bitDepth ~/ 8);
    int fileSize = 36 + pcmData.length;

    ByteData header = ByteData(44);
    int offset = 0;

    // RIFF
    header.setUint8(offset++, 0x52); header.setUint8(offset++, 0x49); 
    header.setUint8(offset++, 0x46); header.setUint8(offset++, 0x46);
    header.setUint32(offset, fileSize, Endian.little); offset += 4;

    // WAVE
    header.setUint8(offset++, 0x57); header.setUint8(offset++, 0x41);
    header.setUint8(offset++, 0x56); header.setUint8(offset++, 0x45);

    // fmt
    header.setUint8(offset++, 0x66); header.setUint8(offset++, 0x6D);
    header.setUint8(offset++, 0x74); header.setUint8(offset++, 0x20);
    header.setUint32(offset, 16, Endian.little); offset += 4;
    header.setUint16(offset, audioFormat, Endian.little); offset += 2;
    header.setUint16(offset, channels, Endian.little); offset += 2;
    header.setUint32(offset, sampleRate, Endian.little); offset += 4;
    header.setUint32(offset, byteRate, Endian.little); offset += 4;
    header.setUint16(offset, blockAlign, Endian.little); offset += 2;
    header.setUint16(offset, bitDepth, Endian.little); offset += 2;

    // data
    header.setUint8(offset++, 0x64); header.setUint8(offset++, 0x61);
    header.setUint8(offset++, 0x74); header.setUint8(offset++, 0x61);
    header.setUint32(offset, pcmData.length, Endian.little);

    Uint8List wavFile = Uint8List(44 + pcmData.length);
    wavFile.setRange(0, 44, header.buffer.asUint8List());
    wavFile.setRange(44, 44 + pcmData.length, pcmData);

    return wavFile;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Recordings'),
      ),
      body: Column(
        children: [
          // Recorder Controls
          Container(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(
                  _isRecording ? Icons.mic : Icons.mic_none,
                  size: 64,
                  color: _isRecording ? Colors.red : Colors.grey,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isRecording ? _stopRecording : _startRecording,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isRecording ? Colors.red : Colors.blue,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      _isRecording ? 'Stop Recording' : 'Start Recording',
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                ),
                if (_isRecording) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Recording... Tap Stop when finished.',
                    style: TextStyle(color: Colors.red),
                  ),
                ],
              ],
            ),
          ),

          const Divider(thickness: 1),

          // Recordings List
          Expanded(
            child: _voiceRecordings.isEmpty
                ? Center(
                    child: Text(
                      'No recordings found',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  )
                : ListView.builder(
                    itemCount: _voiceRecordings.length,
                    itemBuilder: (context, index) {
                      final r = _voiceRecordings[index];
                      return ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.audiotrack),
                        ),
                        title: Text(r['name'] ?? 'Unknown'),
                        subtitle: Text(r['created_at'] ?? ''),
                        trailing: IconButton(
                          icon: const Icon(Icons.download),
                          onPressed: () async {
                             // Existing download logic
                             if (apiService != null) {
                               try {
                                 final path = await apiService!.fetchAndSaveVoiceH(r['id']);
                                 if (mounted) {
                                   ScaffoldMessenger.of(context).showSnackBar(
                                     SnackBar(content: Text('Saved to $path')),
                                   );
                                 }
                               } catch (e) {
                                 // ignore
                               }
                             }
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
