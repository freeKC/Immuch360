// The DIDL-Lite documents of the DLNA media servers: what a Browse of the ContentDirectory answers, one object per
// folder (container) or media file (item), each item with one or more resources (the original file, copies converted
// by the server, thumbnails). The app keeps the folders, the photos and the videos, reads the original resource of
// each, and names them after their titles with an extension, which the browser needs to tell photos from videos.

import 'dart:math';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';

/// One `res` element of an item: a way of getting it, with what the server tells of it
class DidlResource {
  const DidlResource({
    required this.url,
    required this.protocol,
    required this.mimeType,
    this.dlnaParams = const {},
    this.size,
    this.durationMs,
    this.width,
    this.height,
    this.hasOtherResources = false,
  });

  final Uri url;

  /// The first field of the protocolInfo: "http-get" for what a GET reads
  final String protocol;

  /// The third field of the protocolInfo, lower case ("video/mp4")
  final String mimeType;

  /// The fourth field of the protocolInfo, "DLNA.ORG_PN=JPEG_TN;DLNA.ORG_OP=01" read as a map
  final Map<String, String> dlnaParams;
  final int? size;
  final int? durationMs;
  final int? width;
  final int? height;

  /// Whether the item has other resources: a small picture is only a thumbnail when there is something larger
  final bool hasOtherResources;

  static const thumbnailMaxSide = 320;

  /// A picture made by the server to stand for the item: a DLNA thumbnail or small profile (JPEG_TN, PNG_SM...), or
  /// a small picture next to other resources
  bool get isThumbnail {
    final profile = (dlnaParams['DLNA.ORG_PN'] ?? '').toUpperCase();
    if (profile.contains('_TN') || profile.contains('_SM')) {
      return true;
    }
    final width = this.width;
    final height = this.height;
    return hasOtherResources && width != null && height != null && max(width, height) <= thumbnailMaxSide;
  }

  /// A copy converted by the server (DLNA.ORG_CI=1), not the file itself
  bool get isConverted => dlnaParams['DLNA.ORG_CI'] == '1';

  /// Whether the server takes byte ranges for it (the second flag of DLNA.ORG_OP), null when it does not tell
  bool? get byteSeek {
    final operations = dlnaParams['DLNA.ORG_OP'];
    if (operations == null || operations.length < 2) {
      return null;
    }
    return operations[1] == '1';
  }

  bool get _isReadableMedia =>
      protocol == 'http-get' && (mimeType.startsWith('image/') || mimeType.startsWith('video/'));

  @override
  String toString() => 'DidlResource($url $mimeType${size == null ? '' : ' $size'})';
}

/// A container (a folder) or an item (a file) of a DIDL-Lite document
class DidlObject {
  const DidlObject({
    required this.id,
    required this.parentId,
    required this.isContainer,
    required this.title,
    required this.upnpClass,
    this.childCount,
    this.date,
    this.resources = const [],
    this.albumArtUrl,
  });

  /// The object id the server knows it by, for the next Browse
  final String id;
  final String parentId;
  final bool isContainer;

  /// The dc:title, as the server gives it
  final String title;

  /// "object.container.storageFolder", "object.item.videoItem" and the like
  final String upnpClass;
  final int? childCount;
  final DateTime? date;
  final List<DidlResource> resources;
  final Uri? albumArtUrl;

  /// The file itself: among the photos and videos served over HTTP that are no thumbnails, the first not converted
  /// by the server, then the largest, then the first in the document. When all of them have a thumbnail profile, the
  /// largest of them: minidlna and Gerbera give a photo of 640x480 or less the JPEG_SM profile of its own size. Null
  /// for a container, and for an item without a photo or video resource.
  DidlResource? get original {
    DidlResource? best;
    DidlResource? largestSmall;
    for (final resource in resources) {
      if (!resource._isReadableMedia) {
        continue;
      }
      if (resource.isThumbnail) {
        if (largestSmall == null || _isLargerThumbnail(resource, largestSmall)) {
          largestSmall = resource;
        }
        continue;
      }
      if (best == null || _isBetterOriginal(resource, best)) {
        best = resource;
      }
    }
    return best ?? (isContainer ? null : largestSmall);
  }

  static bool _isBetterOriginal(DidlResource candidate, DidlResource best) {
    if (candidate.isConverted != best.isConverted) {
      return !candidate.isConverted;
    }
    return (candidate.size ?? -1) > (best.size ?? -1);
  }

  static bool _isLargerThumbnail(DidlResource candidate, DidlResource best) {
    if (candidate.isConverted != best.isConverted) {
      return !candidate.isConverted;
    }
    final byPixels = _pixels(candidate).compareTo(_pixels(best));
    return byPixels != 0 ? byPixels > 0 : (candidate.size ?? -1) > (best.size ?? -1);
  }

  static int _pixels(DidlResource resource) => (resource.width ?? 0) * (resource.height ?? 0);

  /// The album art, else the smallest thumbnail resource
  Uri? get thumbnailUrl {
    final art = albumArtUrl;
    if (art != null) {
      return art;
    }
    DidlResource? smallest;
    for (final resource in resources) {
      if (resource.protocol != 'http-get' || !resource.mimeType.startsWith('image/') || !resource.isThumbnail) {
        continue;
      }
      if (smallest == null || _area(resource) < _area(smallest)) {
        smallest = resource;
      }
    }
    return smallest?.url;
  }

  static int _area(DidlResource resource) {
    final width = resource.width;
    final height = resource.height;
    if (width != null && height != null) {
      return width * height;
    }
    // Unknown size: after the ones that tell, by file size
    return (1 << 40) + (resource.size ?? 0);
  }

  /// What the browser shows: the folders, and the items that are photos or videos (by their class, or by their
  /// original). Audio and anything else are left out.
  bool get isMedia {
    if (isContainer) {
      return true;
    }
    if (upnpClass.startsWith('object.item.imageItem') || upnpClass.startsWith('object.item.videoItem')) {
      return true;
    }
    return upnpClass.startsWith('object.item') && original != null;
  }

  @override
  String toString() => 'DidlObject(${isContainer ? 'container' : 'item'} $id "$title" $upnpClass)';
}

/// The containers and items of the DIDL-Lite document [didl], in document order, the URLs in it resolved against
/// [base] (the control URL of the server). Objects without an id are left out; nothing is filtered otherwise (see
/// [DidlObject.isMedia]).
List<DidlObject> parseDidlLite(String didl, {required Uri base}) {
  final document = parseLiteXml(didl);
  final root = document.child('DIDL-Lite') ?? document;
  final objects = <DidlObject>[];
  for (final element in root.children) {
    final isContainer = element.name == 'container';
    if (!isContainer && element.name != 'item') {
      continue;
    }
    final id = element.attributes['id'];
    if (id == null || id.isEmpty) {
      continue;
    }
    final resourceElements = element.childrenNamed('res').toList();
    final resources = <DidlResource>[];
    for (final res in resourceElements) {
      final resource = _resourceOf(res, base, hasOthers: resourceElements.length > 1);
      if (resource != null) {
        resources.add(resource);
      }
    }
    final art = element.child('albumArtURI')?.text.trim() ?? '';
    objects.add(
      DidlObject(
        id: id,
        parentId: element.attributes['parentID'] ?? '',
        isContainer: isContainer,
        title: element.child('title')?.text ?? '',
        upnpClass: element.child('class')?.text.trim() ?? '',
        childCount: int.tryParse(element.attributes['childCount'] ?? ''),
        date: _parseDate(element.child('date')?.text.trim() ?? ''),
        resources: resources,
        albumArtUrl: art.isEmpty ? null : _resolve(base, art),
      ),
    );
  }
  return objects;
}

DidlResource? _resourceOf(LiteXmlElement res, Uri base, {required bool hasOthers}) {
  final text = res.text.trim();
  if (text.isEmpty) {
    return null;
  }
  final url = _resolve(base, text);
  if (url == null) {
    return null;
  }
  // protocol:network:contentFormat:additionalInfo, the last one split on ";" into key=value pairs
  final parts = _splitAtMost(res.attributes['protocolInfo'] ?? '', ':', 4);
  final params = <String, String>{};
  if (parts.length == 4) {
    for (final pair in parts[3].split(';')) {
      final equals = pair.indexOf('=');
      if (equals > 0) {
        params[pair.substring(0, equals).trim()] = pair.substring(equals + 1).trim();
      }
    }
  }
  final resolution = RegExp(r'^\s*(\d+)\s*[xX]\s*(\d+)\s*$').firstMatch(res.attributes['resolution'] ?? '');
  // Digits a server wrote may not fit in an int: such a size is left out, as one that does not read
  final width = resolution == null ? null : int.tryParse(resolution.group(1)!);
  final height = resolution == null ? null : int.tryParse(resolution.group(2)!);
  final hasResolution = width != null && height != null;
  return DidlResource(
    url: url,
    protocol: parts.isEmpty ? '' : parts[0].trim().toLowerCase(),
    mimeType: parts.length < 3 ? '' : parts[2].trim().toLowerCase(),
    dlnaParams: params,
    size: int.tryParse((res.attributes['size'] ?? '').trim()),
    durationMs: parseDidlDuration(res.attributes['duration'] ?? ''),
    width: hasResolution ? width : null,
    height: hasResolution ? height : null,
    hasOtherResources: hasOthers,
  );
}

/// [text] split on [separator] into [count] parts at most, the last one keeping the separators it holds
List<String> _splitAtMost(String text, String separator, int count) {
  final parts = <String>[];
  var start = 0;
  while (parts.length < count - 1) {
    final next = text.indexOf(separator, start);
    if (next < 0) {
      break;
    }
    parts.add(text.substring(start, next));
    start = next + separator.length;
  }
  if (text.isNotEmpty) {
    parts.add(text.substring(start));
  }
  return parts;
}

Uri? _resolve(Uri base, String reference) {
  try {
    final url = base.resolve(reference);
    return url.host.isEmpty ? null : url;
  } on FormatException {
    return null;
  }
}

final _duration = RegExp(r'^\s*(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d+)(?:/(\d+))?)?\s*$');

/// Longer than any video; the milliseconds of more hours would not fit in an int
const _maxDurationHours = 1000000;

/// "H+:MM:SS", "H+:MM:SS.F+" or "H+:MM:SS.F0/F1" (DLNA) in milliseconds, null when it does not read. Numbers too
/// long for an int do not read either: they come from the server as it wrote them.
int? parseDidlDuration(String text) {
  final match = _duration.firstMatch(text);
  if (match == null) {
    return null;
  }
  final hours = int.tryParse(match.group(1)!);
  final minutes = int.tryParse(match.group(2)!);
  final seconds = int.tryParse(match.group(3)!);
  if (hours == null || minutes == null || seconds == null || hours > _maxDurationHours) {
    return null;
  }
  var fraction = 0.0;
  final numerator = match.group(4);
  final denominator = match.group(5);
  if (numerator != null) {
    if (denominator != null) {
      final above = int.tryParse(numerator);
      final below = int.tryParse(denominator);
      if (above == null || below == null) {
        return null;
      }
      // F0 < F1 in DLNA: anything else is no fraction of a second
      fraction = below == 0 || above >= below ? 0 : above / below;
    } else {
      // Decimal digits, as many as the server wrote
      fraction = double.parse('0.$numerator');
    }
  }
  return (hours * 3600 + minutes * 60 + seconds) * 1000 + (fraction * 1000).round();
}

/// dc:date, a date alone or with a time; without a zone it is a local time
DateTime? _parseDate(String text) => text.isEmpty ? null : DateTime.tryParse(text);

/// The extensions of the MIME types of the photos and videos, for the items whose URL has none
const _mimeExtensions = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/heif': 'heif',
  'image/avif': 'avif',
  'image/gif': 'gif',
  'image/bmp': 'bmp',
  'image/tiff': 'tif',
  'image/x-adobe-dng': 'dng',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
  'video/x-matroska': 'mkv',
  'video/webm': 'webm',
  'video/x-msvideo': 'avi',
  'video/3gpp': '3gp',
  'video/mp2t': 'mts',
  'video/mpeg': 'mpg',
};

final _unsafeNameCharacters = RegExp(r'[/\\\x00-\x1F\x7F]');

/// The name of [object] in the browser, null for an item that is no photo or video the app knows.
///
/// The title, with the characters a path cannot hold replaced by "_". An item also needs an extension: the one of its
/// original URL when it is a photo or video extension the app knows (Gerbera and minidlna keep the one of the file,
/// raw camera files included), else the one of its MIME type; added unless the title already ends with it.
String? dlnaEntryName(DidlObject object) {
  var base = object.title.trim().replaceAll(_unsafeNameCharacters, '_');
  if (base.isEmpty || base == '.' || base == '..') {
    base = '_';
  }
  if (object.isContainer) {
    return base;
  }
  final original = object.original;
  if (original == null) {
    return null;
  }
  final extension = _extensionOf(original);
  if (extension == null) {
    return null;
  }
  return base.toLowerCase().endsWith('.$extension') ? base : '$base.$extension';
}

String? _extensionOf(DidlResource resource) {
  final segments = resource.url.pathSegments;
  final last = segments.isEmpty ? '' : segments.last;
  final dot = last.lastIndexOf('.');
  if (dot >= 0) {
    final extension = last.substring(dot + 1).toLowerCase();
    if (NetworkEntry.imageExtensions.contains(extension) || NetworkEntry.videoExtensions.contains(extension)) {
      return extension;
    }
  }
  return _mimeExtensions[resource.mimeType.split(';').first.trim()];
}

/// The objects of one listing that have a name (see [dlnaEntryName]), in server order, the names made unique without
/// case: the second "a.jpg" becomes "a (2).jpg", then "a (3).jpg"
List<({DidlObject object, String name})> dlnaEntryNames(Iterable<DidlObject> objects) {
  final taken = <String>{};
  final named = <({DidlObject object, String name})>[];
  for (final object in objects) {
    final name = dlnaEntryName(object);
    if (name == null) {
      continue;
    }
    var unique = name;
    if (!taken.add(name.toLowerCase())) {
      final dot = object.isContainer ? -1 : name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final extension = dot > 0 ? name.substring(dot) : '';
      for (var n = 2; ; n++) {
        unique = '$stem ($n)$extension';
        if (taken.add(unique.toLowerCase())) {
          break;
        }
      }
    }
    named.add((object: object, name: unique));
  }
  return named;
}
