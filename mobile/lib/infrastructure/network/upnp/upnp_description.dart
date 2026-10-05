// The device description of a UPnP media server (the XML document at the LOCATION of its SSDP answer, the address the
// user pastes): its name, its id, and where its ContentDirectory service takes the Browse requests. Nothing else of
// the description matters to the app.

import 'package:immich_mobile/infrastructure/network/lite_xml.dart';

/// What the app needs of a UPnP media server, see [parseUpnpDescription]
class UpnpDevice {
  const UpnpDevice({
    required this.friendlyName,
    required this.udn,
    required this.contentDirectoryControl,
    required this.contentDirectoryType,
    this.manufacturer,
    this.modelName,
  });

  /// The name the server gives itself, trimmed; may be empty
  final String friendlyName;

  /// "uuid:...", stable across restarts and address changes; may be empty on a broken server
  final String udn;

  /// Where the SOAP Browse requests go, absolute
  final Uri contentDirectoryControl;

  /// The full service type ("urn:schemas-upnp-org:service:ContentDirectory:1"), part of the SOAP action
  final String contentDirectoryType;

  final String? manufacturer;
  final String? modelName;

  @override
  String toString() => 'UpnpDevice($friendlyName $udn $contentDirectoryControl)';
}

const _contentDirectoryPrefix = 'urn:schemas-upnp-org:service:ContentDirectory:';

/// The media server described by [xml], fetched from [location]; null when no device of it offers a ContentDirectory
/// service, or when its control URL does not read.
///
/// Elements are matched by local name in any namespace: servers declare "urn:schemas-upnp-org:device-1-0" in
/// practice, but not all of them, nor always as the default namespace. The devices are searched depth first from the
/// root device, as Jellyfin and some NAS put the media server in an embedded device.
UpnpDevice? parseUpnpDescription(String xml, Uri location) {
  final root = parseLiteXml(xml).child('root');
  if (root == null) {
    return null;
  }
  final base = _baseOf(root, location);
  final rootDevice = root.child('device');
  if (rootDevice == null) {
    return null;
  }
  final stack = [rootDevice];
  while (stack.isNotEmpty) {
    final device = stack.removeLast();
    final found = _contentDirectoryOf(device, base);
    if (found != null) {
      return found;
    }
    final embedded = [for (final list in device.childrenNamed('deviceList')) ...list.childrenNamed('device')];
    // In document order: the first embedded device is searched first
    stack.addAll(embedded.reversed);
  }
  return null;
}

/// URLBase when it is there and absolute (UPnP 1.0; deprecated since, but still sent by a few servers), else the
/// address the description came from
Uri _baseOf(LiteXmlElement root, Uri location) {
  final text = root.child('URLBase')?.text.trim() ?? '';
  if (text.isEmpty) {
    return location;
  }
  final base = Uri.tryParse(text);
  if (base == null || !base.isAbsolute || base.host.isEmpty || (base.scheme != 'http' && base.scheme != 'https')) {
    return location;
  }
  return base;
}

UpnpDevice? _contentDirectoryOf(LiteXmlElement device, Uri base) {
  // Its own services, not those of its embedded devices
  for (final service in device.childrenNamed('serviceList').expand((list) => list.childrenNamed('service'))) {
    final type = service.child('serviceType')?.text.trim() ?? '';
    if (!type.startsWith(_contentDirectoryPrefix)) {
      continue;
    }
    final control = service.child('controlURL')?.text.trim() ?? '';
    if (control.isEmpty) {
      return null;
    }
    final Uri resolved;
    try {
      resolved = base.resolve(control);
    } on FormatException {
      return null;
    }
    if (resolved.host.isEmpty || (resolved.scheme != 'http' && resolved.scheme != 'https')) {
      return null;
    }
    String? optional(String name) {
      final value = device.child(name)?.text.trim() ?? '';
      return value.isEmpty ? null : value;
    }

    return UpnpDevice(
      friendlyName: device.child('friendlyName')?.text.trim() ?? '',
      udn: device.child('UDN')?.text.trim() ?? '',
      contentDirectoryControl: resolved,
      contentDirectoryType: type,
      manufacturer: optional('manufacturer'),
      modelName: optional('modelName'),
    );
  }
  return null;
}
