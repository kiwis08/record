import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

/// The name of the Phiola executable.
const _phiolaBin = 'phiola';

/// A constant used to form a unique pipe name for global commands.
const _pipeProcName = 'record_linux';

/// A Linux implementation of the RecordPlatform using Phiola.
class RecordLinux extends RecordPlatform {
  static void registerWith() {
    RecordPlatform.instance = RecordLinux();
  }

  RecordState _state = RecordState.stop;
  String? _path;
  StreamController<RecordState>? _stateStreamCtrl;

  @override
  Future<void> create(String recorderId) async {
    // Initialization code (if needed) goes here.
  }

  @override
  Future<void> dispose(String recorderId) async {
    await stop(recorderId);
    await _stateStreamCtrl?.close();
  }

  @override
  Future<Amplitude> getAmplitude(String recorderId) async {
    // Phiola may not support amplitude queries; return a default value.
    return Amplitude(current: -160.0, max: -160.0);
  }

  @override
  Future<bool> hasPermission(String recorderId) async {
    // On Linux, permissions are generally granted by default.
    return true;
  }

  @override
  Future<bool> isEncoderSupported(
      String recorderId, AudioEncoder encoder) async {
    switch (encoder) {
      case AudioEncoder.aacLc:
      case AudioEncoder.aacHe:
      case AudioEncoder.flac:
      case AudioEncoder.opus:
      case AudioEncoder.wav:
        return true;
      default:
        return false;
    }
  }

  @override
  Future<bool> isPaused(String recorderId) async {
    return _state == RecordState.pause;
  }

  @override
  Future<bool> isRecording(String recorderId) async {
    return _state == RecordState.record;
  }

  @override
  Future<void> pause(String recorderId) async {
    if (_state == RecordState.record) {
      // Tell Phiola to pause recording.
      await _callPhiola(['--globcmd=pause'], recorderId: recorderId);
      _updateState(RecordState.pause);
    }
  }

  @override
  Future<void> resume(String recorderId) async {
    if (_state == RecordState.pause) {
      // Tell Phiola to resume recording.
      await _callPhiola(['--globcmd=unpause'], recorderId: recorderId);
      _updateState(RecordState.record);
    }
  }

  @override
  Future<void> start(
      String recorderId,
      RecordConfig config, {
        required String path,
      }) async {
    // Stop any existing recording.
    await stop(recorderId);

    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }

    // Verify that the encoder is supported.
    if (!await isEncoderSupported(recorderId, config.encoder)) {
      throw Exception('${config.encoder} is not supported.');
    }

    // Convert number of channels to a string as expected by Phiola.
    String numChannels;
    if (config.numChannels == 6) {
      numChannels = '5.1';
    } else if (config.numChannels == 8) {
      numChannels = '7.1';
    } else if (config.numChannels == 1 || config.numChannels == 2) {
      numChannels = config.numChannels.toString();
    } else {
      throw Exception(
          '${config.numChannels} channels configuration is not supported.');
    }

    final args = <String>[
      '--notui',
      '--background',
      '--record',
      '--out=$path',
      '--rate=${config.sampleRate}',
      '--channels=$numChannels',
      '--globcmd=listen',
      '--gain=6.0',
      if (config.device != null) '--dev-capture=${config.device!.id}',
      ..._getEncoderSettings(config.encoder, config.bitRate),
    ];

    await _callPhiola(
      args,
      recorderId: recorderId,
      consumeOutput: false,
      onStarted: () {
        _path = path;
        _updateState(RecordState.record);
      },
    );
  }

  @override
  Future<String?> stop(String recorderId) async {
    final path = _path;

    // Signal Phiola to stop recording and then quit.
    await _callPhiola(['--globcmd=stop'], recorderId: recorderId);
    await _callPhiola(['--globcmd=quit'], recorderId: recorderId);
    _updateState(RecordState.stop);
    return path;
  }

  @override
  Future<void> cancel(String recorderId) async {
    final path = await stop(recorderId);
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async {
    final outStreamCtrl = StreamController<List<int>>();
    final lines = <String>[];

    // Capture the output of the Phiola device listing.
    outStreamCtrl.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      lines.add(line);
    });

    try {
      await _callPhiola(
        ['--list-dev'],
        recorderId: recorderId,
        outStreamCtrl: outStreamCtrl,
      );
      return _parseInputDevices(lines);
    } finally {
      await outStreamCtrl.close();
    }
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) {
    _stateStreamCtrl ??= StreamController<RecordState>(
      onCancel: () {
        _stateStreamCtrl?.close();
        _stateStreamCtrl = null;
      },
    );
    return _stateStreamCtrl!.stream;
  }

  /// Returns command-line arguments for the selected encoder.
  List<String> _getEncoderSettings(AudioEncoder encoder, int bitRate) {
    switch (encoder) {
      case AudioEncoder.aacLc:
        return ['--aac-profile=LC', '--bitrate=${bitRate}k'];
      case AudioEncoder.aacHe:
        return ['--aac-profile=HEv2', '--bitrate=${bitRate}k'];
      case AudioEncoder.flac:
        return ['--flac-compression=6'];
      case AudioEncoder.opus:
        return ['--opus.bitrate=${bitRate}k'];
      case AudioEncoder.wav:
        return [];
      default:
        throw Exception('Encoder ${encoder.toString()} not supported by Phiola.');
    }
  }

  /// Calls the Phiola process with the given arguments.
  Future<void> _callPhiola(
      List<String> arguments, {
        required String recorderId,
        StreamController<List<int>>? outStreamCtrl,
        VoidCallback? onStarted,
        bool consumeOutput = true,
      }) async {
    // Start the Phiola process.
    final process = await Process.start(_phiolaBin, [
      '--globcmd.pipe-name=$_pipeProcName$recorderId',
      ...arguments,
    ]);

    // Immediately invoke the onStarted callback if provided.
    if (onStarted != null) {
      onStarted();
    }

    // Consume output streams to avoid process hanging.
    if (consumeOutput) {
      final outController = outStreamCtrl ?? StreamController<List<int>>();
      if (outStreamCtrl == null) {
        outController.stream.listen((_) {});
      }
      final errController = StreamController<List<int>>();
      errController.stream.listen((_) {});

      await Future.wait([
        outController.addStream(process.stdout),
        errController.addStream(process.stderr),
      ]);

      if (outStreamCtrl == null) {
        await outController.close();
      }
      await errController.close();
    }
  }

  /// Parses the output of the device listing command and returns a list
  /// of [InputDevice] instances.
  List<InputDevice> _parseInputDevices(List<String> lines) {
    final devices = <InputDevice>[];
    String currentDeviceLine = '';

    void extractDevice({String? details}) {
      if (currentDeviceLine.isNotEmpty) {
        final device = _extractDevice(currentDeviceLine, details: details);
        if (device != null) {
          devices.add(device);
        }
        currentDeviceLine = '';
      }
    }

    bool captureSection = false;
    for (final line in lines) {
      // Look for the "Capture:" header before processing devices.
      if (!captureSection) {
        if (line.trim() == 'Capture:') {
          captureSection = true;
        }
        continue;
      }

      if (line.startsWith(RegExp(r'^device #'))) {
        // Found a new device line; extract any previous device.
        extractDevice();
        currentDeviceLine = line;
      } else if (line.startsWith(RegExp(r'^\s*Default Format:'))) {
        extractDevice(details: line);
      }
    }
    // Extract any remaining device.
    extractDevice();
    return devices;
  }

  /// Extracts an [InputDevice] from the given text lines.
  InputDevice? _extractDevice(String firstLine, {String? details}) {
    final match = RegExp(r'device #(\d+): (.+)').firstMatch(firstLine);
    if (match == null) return null;
    final id = match.group(1);
    var label = match.group(2) ?? '';

    // Remove the " - Default" suffix if present.
    if (label.contains(' - Default')) {
      label = label.replaceAll(' - Default', '');
    }
    return InputDevice(id: id!, label: label);
  }

  /// Updates the internal recording state and notifies listeners.
  void _updateState(RecordState newState) {
    if (_state == newState) return;
    _state = newState;
    _stateStreamCtrl?.add(newState);
  }
}
