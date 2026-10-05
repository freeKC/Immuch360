// The calibrations of the Insta360 cameras met in the trailers of their files, kept by camera serial in a small JSON
// file of the app, and the last one of each camera model. A file without a calibration of its own (an HDR member, a
// copy whose trailer was cut) from a camera seen before is drawn with that camera's calibration rather than the nominal
// values of its model, whose seams are off by a few pixels. One that names its model but not its camera (the members
// _008 and _009 of an X3 HDR group have no trailer, and their EXIF gives the model only) is drawn with the last
// calibration of that model: most often the same camera's, as few people own two of one model.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('DualFisheyeCalibrationStore');

/// The calibrations kept: by camera serial, and the last one of each camera model
typedef _Calibrations = ({Map<String, DualFisheyeCalibration> cameras, Map<String, DualFisheyeCalibration> models});

/// The calibrations of the cameras seen, in the JSON file [file] gives; none when it gives null: nothing is read nor
/// written then. Read once, on first use; each change is written at once, one write after the other.
class DualFisheyeCalibrationStore {
  DualFisheyeCalibrationStore(this._file);

  /// The store of the app, in its support directory
  factory DualFisheyeCalibrationStore.appSupport() =>
      DualFisheyeCalibrationStore(() async => File(p.join((await getApplicationSupportDirectory()).path, fileName)));

  /// Name of the file of the store in the support directory of the app
  static const fileName = 'dual_fisheye_calibrations.json';

  static const _version = 1;

  final Future<File?> Function() _file;

  Future<_Calibrations>? _loading;
  Future<void> _writing = Future.value();

  /// Keeps [calibration], read from a file of the camera [serial], for the files of that camera without one, and as
  /// the last calibration of its camera model (see [forModel]). Only a calibration of an Insta360 camera from the file
  /// itself is kept: a cached or nominal one would hide a later real one, and every file of a DJI camera carries its
  /// own (its nominal values are close enough for one that does not). Gravity is not kept, it belongs to the shot.
  Future<void> remember(String serial, DualFisheyeCalibration calibration) async {
    if (serial.isEmpty ||
        calibration.source != DualFisheyeSource.file ||
        calibration.model == DualFisheyeModel.kannalaBrandt) {
      return;
    }
    // As the file keeps it: the layout of the video and the gravity of the shot belong to the file it came from
    final kept = DualFisheyeCalibration.fromJson(
      calibration.copyWith(serial: serial, downBody: const [1.0, 0.0, 0.0]).toJson(),
    );
    final model = calibration.cameraModel?.trim() ?? '';
    final calibrations = await _load();
    var changed = _put(calibrations.cameras, serial, kept);
    if (model.isNotEmpty) {
      changed = _put(calibrations.models, model, kept) || changed;
    }
    // Each file of the camera tells the same: the file is written again only when a calibration changed
    if (changed) {
      await _save(calibrations);
    }
  }

  /// The calibration kept for the camera [serial], marked as coming from the cache, with the gravity [downBody] of the
  /// shot (the camera upright when null); null when that camera was never seen
  Future<DualFisheyeCalibration?> forSerial(String serial, {List<double>? downBody}) async =>
      _cached((await _load()).cameras[serial], downBody);

  /// The last calibration kept for a camera of [model] ("Insta360 X3"), for a file that names its model but not its
  /// camera; marked as coming from the cache, with the gravity [downBody] of the shot (the camera upright when null).
  /// Null when no camera of that model was seen.
  Future<DualFisheyeCalibration?> forModel(String model, {List<double>? downBody}) async =>
      _cached((await _load()).models[model.trim()], downBody);

  DualFisheyeCalibration? _cached(DualFisheyeCalibration? calibration, List<double>? downBody) =>
      calibration?.copyWith(source: DualFisheyeSource.cachedSerial, downBody: downBody ?? const [1.0, 0.0, 0.0]);

  // Puts [calibration] under [key] in [calibrations]; whether that changed them
  static bool _put(Map<String, DualFisheyeCalibration> calibrations, String key, DualFisheyeCalibration calibration) {
    final previous = calibrations[key];
    if (previous != null && jsonEncode(previous.toJson()) == jsonEncode(calibration.toJson())) {
      return false;
    }
    calibrations[key] = calibration;
    return true;
  }

  Future<_Calibrations> _load() => _loading ??= _read();

  Future<_Calibrations> _read() async {
    final _Calibrations calibrations = (cameras: {}, models: {});
    try {
      final file = await _file();
      // ignore: avoid_slow_async_io
      if (file == null || !await file.exists()) {
        return calibrations;
      }
      final json = jsonDecode(await file.readAsString());
      if (json is Map) {
        _readEntries(json['cameras'], calibrations.cameras, 'camera');
        // Absent from the files written before the models were kept
        _readEntries(json['models'], calibrations.models, 'camera model');
      }
    } catch (error, stackTrace) {
      // A store that cannot be read only means files without a calibration get the nominal one
      _log.warning('Could not read the calibrations of the cameras', error, stackTrace);
    }
    return calibrations;
  }

  // Reads the calibrations of [json], a map of [what] to calibration, into [calibrations]
  static void _readEntries(Object? json, Map<String, DualFisheyeCalibration> calibrations, String what) {
    if (json is! Map) {
      return;
    }
    for (final MapEntry(:key, :value) in json.entries) {
      // One damaged entry loses that camera only
      try {
        if (key is String && value is Map) {
          calibrations[key] = DualFisheyeCalibration.fromJson(value.cast());
        }
      } catch (error) {
        _log.warning('Could not read the calibration of the $what $key', error);
      }
    }
  }

  /// Writes [calibrations] as they are now, after the writes under way
  Future<void> _save(_Calibrations calibrations) {
    Map<String, Object?> entries(Map<String, DualFisheyeCalibration> calibrations) => {
      for (final MapEntry(:key, :value) in calibrations.entries) key: value.toJson(),
    };
    final json = jsonEncode({
      'version': _version,
      'cameras': entries(calibrations.cameras),
      'models': entries(calibrations.models),
    });
    final write = _writing.then((_) => _write(json));
    _writing = write;
    return write;
  }

  Future<void> _write(String json) async {
    try {
      final file = await _file();
      if (file == null) {
        return;
      }
      await file.parent.create(recursive: true);
      // A temporary file renamed over the store: the app stopped in the middle of a write leaves the previous one
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(json, flush: true);
      await temporary.rename(file.path);
    } catch (error, stackTrace) {
      _log.warning('Could not write the calibrations of the cameras', error, stackTrace);
    }
  }
}
