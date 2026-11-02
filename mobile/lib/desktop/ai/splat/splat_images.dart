// The preparation of the images of a splat scene as the app gives it to the engine (splat_engine.dart, lot SP6): the
// photos of lot SP5 (splat_inputs.dart: 200 at most spread in time, turned upright, reduced to 1 600 pixels, the
// blurred ones left out, one folder per camera) or the frames of the video (video_frames.dart), taken by a player of
// the app's libmpv made for the job and closed after it (mpv_frame_source.dart: one does not open again once closed).
// Apart from the engine because it needs Flutter: the engine runs in a program compiled without it too.

import 'package:immich_mobile/desktop/ai/codec/engine_picture.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/dart_immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/mpv_frame_source.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_inputs.dart';
import 'package:immich_mobile/desktop/ai/splat/video_frames.dart';

/// The images of a job as the app prepares them (see the top of this file); [frameSource] makes the source of the
/// frames of each video, [decodeOther] decodes a photo the JPEG codec does not read (the engine of the app by default)
SplatImagesMaker appSplatImages({SplatFrameSource Function()? frameSource, OtherPhotoDecoder? decodeOther}) =>
    (members, {required video, required imagesFolder, required cancel, required onProgress}) async {
      try {
        final SplatInputs inputs;
        if (video) {
          final source = (frameSource ?? MpvSplatFrameSource.new)();
          inputs = await takeMemberFrames(
            members.single,
            source: source,
            imagesFolder: imagesFolder,
            cancel: cancel,
            onProgress: onProgress,
          );
        } else {
          inputs = await prepareSplatPhotos(
            planSplatPhotos(members).taken,
            imagesFolder: imagesFolder,
            cancel: cancel,
            onProgress: onProgress,
            decodeOther: decodeOther ?? decodeWithEngine,
          );
        }
        return SplatPrepared(images: inputs.images.length, total: inputs.total, blurred: inputs.blurred);
      } on ConversionException catch (error) {
        throw BackendException(error.code, error.message ?? error.code.name);
      }
    };
