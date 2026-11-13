// What the players of a film decode, in Plex's names (see film_player_choice.dart).
//
// The device's player (Media3 on Android): the containers its extractors read, and the codecs the device's decoders
// list (MediaCodecList), asked once per run of the app (DeviceDecoderTypes) and mapped from their MIME types here.
// Media3 also plays raw PCM without a decoder.
//
// libmpv of the Quest build: the decoders of the FFmpeg inside the libmpv of media-kit's libmpv-android-video-build
// v1.1.7 (default-arm64-v8a.jar, read from its configure line on 11 November 2026: --disable-decoders, then the list
// below). It has DTS (dca), DivX 3 (msmpeg4v3), WMA and WMV, AC-3 and E-AC-3, but neither TrueHD (mlp, truehd) nor
// VC-1, nor the PGS subtitles of Blu-ray discs.
//
// The libmpv of the computers (immuch360/libmpv-builds libmpv-windows-20261113-2 and libmpv-macos-20261113-2, through
// media_kit_360 v1.1.1 and the macOS Package.swift) decodes Dolby TrueHD and MLP, and PGS subtitles; the 20261110-1
// builds had neither TrueHD nor MLP (and Windows no PGS). Linux takes the system's libmpv, whose FFmpeg has every
// decoder. iOS plays with AVFoundation.

import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';

/// The MIME types of the Android decoders for each codec of Plex: the device decodes the codec when it lists one of
/// them. A codec missing here has no Android decoder (DivX 3, WMV, VC-1, WMA).
const plexCodecMimeTypes = <String, List<String>>{
  'h264': ['video/avc'],
  'hevc': ['video/hevc', 'video/dolby-vision'],
  'av1': ['video/av01'],
  'vp8': ['video/x-vnd.on2.vp8'],
  'vp9': ['video/x-vnd.on2.vp9'],
  'mpeg4': ['video/mp4v-es'],
  'mpeg2video': ['video/mpeg2'],
  'mpeg1video': ['video/mpeg2'],
  'h263': ['video/3gpp'],
  'aac': ['audio/mp4a-latm'],
  'ac3': ['audio/ac3'],
  'eac3': ['audio/eac3', 'audio/eac3-joc'],
  'dca': ['audio/vnd.dts', 'audio/vnd.dts.hd'],
  'dts': ['audio/vnd.dts', 'audio/vnd.dts.hd'],
  'truehd': ['audio/true-hd'],
  'mp3': ['audio/mpeg'],
  'mp2': ['audio/mpeg-l2'],
  'flac': ['audio/flac'],
  'opus': ['audio/opus'],
  'vorbis': ['audio/vorbis'],
  'alac': ['audio/alac'],
  'ac4': ['audio/ac4'],
};

/// The containers Media3's extractors read (Plex's names)
const media3Containers = {
  'mkv',
  'webm',
  'mp4',
  'm4v',
  'mov',
  'avi',
  'mpegts',
  'ts',
  'm2ts',
  'mpeg',
  'flv',
  'ogg',
  'wav',
  'mp3',
  'aac',
  'flac',
  '3gp',
};

/// The audio Media3 plays without a decoder of the device
const media3OwnAudio = {'pcm', 'pcm_s16le', 'pcm_s24le', 'pcm_s16be', 'pcm_s24be', 'lpcm'};

/// H.264 profiles the decoders of phones and headsets do not list (10 bit and 4:2:2 or 4:4:4): Media3 then fails
const deviceRefusedVideoProfiles = <String, Set<String>>{
  'h264': {'high 10', 'high 10 intra', 'high 4:2:2', 'high 4:2:2 intra', 'high 4:4:4 predictive'},
  // MPEG-4 part 2 beyond its simple profile (DivX 4 to 6, Xvid with B frames or quarter pel): the software decoder of
  // Android decodes the simple profile only
  'mpeg4': {'advanced simple'},
};

/// What the device's player decodes, from the MIME types of its decoders ([mimeTypes], lower case)
FilmDecoders deviceFilmDecoders(Set<String> mimeTypes) {
  final video = <String>{};
  final audio = <String>{...media3OwnAudio};
  for (final MapEntry(key: codec, value: mimes) in plexCodecMimeTypes.entries) {
    if (mimes.any(mimeTypes.contains)) {
      (mimes.first.startsWith('video/') ? video : audio).add(codec);
    }
  }
  return FilmDecoders(
    containers: media3Containers,
    video: video,
    audio: audio,
    refusedVideoProfiles: deviceRefusedVideoProfiles,
  );
}

/// What the libmpv of the Quest build decodes (see the top of this file)
const mpvFilmDecoders = FilmDecoders(
  containers: {
    'mkv',
    'webm',
    'mp4',
    'm4v',
    'mov',
    'avi',
    'mpegts',
    'ts',
    'm2ts',
    'mpeg',
    'flv',
    'ogg',
    'asf',
    'wmv',
    'rm',
    'wav',
    'mp3',
    'aac',
    'flac',
    'ac3',
    'dts',
  },
  video: {
    'h264',
    'hevc',
    'av1',
    'vp8',
    'vp9',
    'vp6',
    'vp6f',
    'mpeg4',
    'msmpeg4',
    'msmpeg4v1',
    'msmpeg4v2',
    'msmpeg4v3',
    'wmv1',
    'wmv2',
    'wmv3',
    'mpeg1video',
    'mpeg2video',
    'h263',
    'flv',
    'flv1',
    'theora',
    'mjpeg',
  },
  audio: {
    'aac',
    'ac3',
    'eac3',
    'dca',
    'dts',
    'mp3',
    'mp2',
    'mp1',
    'flac',
    'opus',
    'vorbis',
    'alac',
    'als',
    'ape',
    'wavpack',
    'wmav1',
    'wmav2',
    'wmapro',
    'wmalossless',
    'pcm',
    'pcm_s16le',
    'pcm_s24le',
    'pcm_s16be',
    'pcm_s24be',
    'lpcm',
    'tta',
    'tak',
    'ra_144',
    'ra_288',
  },
);

/// The audio codecs the libmpv of the Quest build (media-kit v1.1.7, re-hosted) does not decode. A track in one of them
/// is not played by mpv; any other codec is left to mpv, which says at run time when it cannot. The computers' builds
/// decode them since the 20261113-2 releases.
const libmpvMissingAudioCodecs = {'truehd', 'mlp'};

/// What libmpv does not decode of the audio on this system: TrueHD and MLP on the Quest, nothing on the computers
Set<String> libmpvMissingAudioOn({required bool android}) => android ? libmpvMissingAudioCodecs : const {};

/// The audio AVFoundation plays on iPhone and iPad (no DTS, no TrueHD)
const iosAudioCodecs = {
  'aac',
  'ac3',
  'eac3',
  'mp3',
  'alac',
  'flac',
  'opus',
  'pcm',
  'pcm_s16le',
  'pcm_s24le',
  'pcm_s16be',
  'pcm_s24be',
  'lpcm',
};
