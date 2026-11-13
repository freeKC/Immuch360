// Where the live view of a camera comes from: RTSP with the camera account, the media port with the TP-Link password
// for the cameras without RTSP (battery and solar ones, told by their power or their C4xx model), the hub refused,
// and what each case asks the user for.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';

void main() {
  TapoLiveRoute route({
    String? model,
    String? power,
    String? deviceType,
    bool account = true,
    bool cloud = true,
    bool rtspFailed = false,
  }) => tapoLiveRoute(
    model: model,
    power: power,
    deviceType: deviceType,
    hasCameraAccount: account,
    hasCloudPassword: cloud,
    rtspFailed: rtspFailed,
  );

  test('tells the battery and solar cameras by their power, else by their model', () {
    expect(tapoIsBatteryCamera(power: 'BATTERY'), isTrue);
    expect(tapoIsBatteryCamera(power: 'solar'), isTrue);
    expect(tapoIsBatteryCamera(model: 'C410'), isTrue);
    for (final model in ['C400', 'C402', 'C420', 'C425', 'C460', 'c410']) {
      expect(tapoIsBatteryCamera(model: model), isTrue, reason: model);
    }
    expect(tapoIsBatteryCamera(model: 'C510W'), isFalse);
    expect(tapoIsBatteryCamera(model: 'C200', power: 'MAINS'), isFalse);
    expect(tapoIsBatteryCamera(), isFalse);
  });

  test('tells a hub by its type or its model', () {
    expect(tapoIsHub(deviceType: 'SMART.TAPOHUB'), isTrue);
    expect(tapoIsHub(model: 'H200'), isTrue);
    expect(tapoIsHub(model: 'C410', deviceType: 'SMART.IPCAMERA'), isFalse);
  });

  test('a mains camera: RTSP with the camera account, else the media port, else the hint', () {
    expect(route(model: 'C510W'), TapoLiveRoute.rtsp);
    expect(route(model: 'C510W', account: false), TapoLiveRoute.mediaPort);
    expect(route(model: 'C510W', account: false, cloud: false), TapoLiveRoute.needsAccount);
  });

  test('a battery camera: the media port, whatever the camera account', () {
    expect(route(model: 'C410'), TapoLiveRoute.mediaPort);
    expect(route(model: 'C410', account: false), TapoLiveRoute.mediaPort);
    expect(route(power: 'BATTERY'), TapoLiveRoute.mediaPort);
    expect(route(model: 'C410', cloud: false), TapoLiveRoute.needsCloudPassword);
  });

  test('RTSP that did not start: the media port when it can', () {
    expect(route(model: 'C999', rtspFailed: true), TapoLiveRoute.mediaPort);
    expect(route(model: 'C999', rtspFailed: true, cloud: false), TapoLiveRoute.needsCloudPassword);
  });

  test('a hub is said so', () {
    expect(route(model: 'H200', deviceType: 'SMART.TAPOHUB'), TapoLiveRoute.hub);
  });

  test('the camera info keeps the power and the type across a store', () {
    const info = TapoCameraInfo(model: 'C410', power: 'BATTERY', deviceType: 'SMART.IPCAMERA');
    final again = TapoCameraInfo.fromJson(info.toJson());
    expect(again, info);
    expect((again.power, again.deviceType), ('BATTERY', 'SMART.IPCAMERA'));
    expect(TapoCameraInfo.fromJson({'model': 'C200'}).power, isNull);
    expect(info.copyWith(firmware: '1.3.5').power, 'BATTERY');
  });
}
