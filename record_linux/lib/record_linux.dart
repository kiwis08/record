import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

const _phiolaBin = 'phiola';
const _pipeProcName = 'record_linux';

class RecordLinux extends RecordPlatform {
  static void registerWith() {
    RecordPlatform.instance = RecordLinux();
  }

  RecordState _state = RecordState.stop;
  String? _path;
  StreamController<RecordState>? _stateStreamCtrl;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<void> dispose(String recorderId) {
    _stateStreamCtrl?.close();
    return stop(recorderId);
  }

  @override
  Future<Amplitude> getAmplitude(String recorderId) {
    return Future.value(Amplitude(current: -160.0, max: -160.0));
  }

  @override
  Future<bool> hasPermission(String recorderId) {
    return Future.value(true);
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
  Future<bool> isPaused(String recorderId) {
    return Future.value(_state == RecordState.pause);
  }

  @override
  Future<bool> isRecording(String recorderId) {
    return Future.value(_state == RecordState.record);
  }

  @override
  Future<void> pause(String recorderId) async {
    if (_state == RecordState.record) {
      await _callPhiola(['remote', 'pause'], recorderId: recorderId);
      _updateState(RecordState.pause);
    }
  }

  @override
  Future<void> resume(String recorderId) async {
    if (_state == RecordState.pause) {
      await _callPhiola(['remote', 'unpause'], recorderId: recorderId);
      _updateState(RecordState.record);
    }
  }

  @override
  Future<void> start(
      String recorderId,
      RecordConfig config, {
        required String path,
      }) async {
    await stop(recorderId);

    final file = File(path);
    if (file.existsSync()) await file.delete();

    final supported = await isEncoderSupported(recorderId, config.encoder);
    if (!supported) {
      throw Exception('${config.encoder} is not supported.');
    }

    await _callPhiola(
      [
        'record',
        '-o', path,
        '-rate', '${config.sampleRate}',
        '-channels', '${config.numChannels}',
        if (config.device != null) '-dev',
        if (config.device != null) config.device!.id,
      ],
      onStarted: () {
        _path = path;
        _updateState(RecordState.record);
      },
      consumeOutput: false,
      recorderId: recorderId,
    );
  }

  @override
  Future<String?> stop(String recorderId) async {
    final path = _path;
    try {
      await _callPhiola(['remote', 'stop'], recorderId: recorderId);
    } catch (e) {
      if (e.toString().contains('No such file or directory')) {
        return null;
      } else {
        rethrow;
      }
    }
    _updateState(RecordState.stop);
    return path;
  }

  @override
  Future<void> cancel(String recorderId) async {
    final path = await stop(recorderId);
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  }

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async {
    final outStreamCtrl = StreamController<List<int>>();
    final out = <String>[];

    outStreamCtrl.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((chunk) {
      out.add(chunk);
    });

    try {
      await _callPhiola(['device', 'list'],
          recorderId: '', outStreamCtrl: outStreamCtrl);
      return _listInputDevices(recorderId, out);
    } finally {
      outStreamCtrl.close();
    }
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) {
    _stateStreamCtrl ??= StreamController(
      onCancel: () {
        _stateStreamCtrl?.close();
        _stateStreamCtrl = null;
      },
    );

    return _stateStreamCtrl!.stream;
  }

  Future<void> _callPhiola(
      List<String> arguments, {
        required String recorderId,
        StreamController<List<int>>? outStreamCtrl,
        VoidCallback? onStarted,
        bool consumeOutput = true,
      }) async {
    final process = await Process.start(_phiolaBin, arguments);

    if (onStarted != null) {
      onStarted();
    }

    if (consumeOutput) {
      final out = outStreamCtrl ?? StreamController<List<int>>();
      if (outStreamCtrl == null) out.stream.listen((event) {});
      final err = StreamController<List<int>>();
      err.stream.listen((event) {});

      await Future.wait([
        out.addStream(process.stdout),
        err.addStream(process.stderr),
      ]);

      if (outStreamCtrl == null) out.close();
      err.close();
    }
  }

  Future<List<InputDevice>> _listInputDevices(
      String recorderId,
      List<String> out,
      ) async {
    final devices = <InputDevice>[];
    for (var line in out) {
      if (line.startsWith('device #')) {
        final parts = line.split(': ');
        if (parts.length == 2) {
          devices.add(InputDevice(id: parts[0].split('#')[1], label: parts[1]));
        }
      }
    }
    return devices;
  }

  void _updateState(RecordState state) {
    if (_state == state) return;
    _state = state;
    if (_stateStreamCtrl?.hasListener ?? false) {
      _stateStreamCtrl?.add(state);
    }
  }
}
