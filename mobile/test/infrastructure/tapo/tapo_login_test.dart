// The logins of the cameras against the fake camera: V4 with the md5 and the SHA-256 passcodes (and the shadow of a
// C200), the user name forms, V3 with both password hashes, V2; the refusals, the lockout fields, and the rules that
// keep a camera from locking: an empty password never sent, two passcodes at most on a first login, only the one that
// worked on a later one (once more after the pause), never a loop.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_login.dart';

import 'fake_tapo_camera.dart';

const _password = 'synthetic-cloud-password';

TapoLogin _login(FakeTapoCamera camera) =>
    TapoLogin(camera, spake2p: (input) async => spake2pClient(input), reloginDelay: Duration.zero);

Future<Map<String, Object?>> _deviceInfo(TapoSession session) => session.multiple([
  {
    'method': 'getDeviceInfo',
    'params': {
      'device_info': {
        'name': ['basic_info'],
      },
    },
  },
]);

Map<String, Object?> _firstResult(Map<String, Object?> answer) =>
    (((answer['result']! as Map)['responses'] as List).first as Map).cast<String, Object?>();

TapoCameraException _refusal(Object error) => error as TapoCameraException;

void main() {
  group('V4', () {
    test('logs in with the md5 passcode, detected by the V3 probe, and the channel answers', () async {
      final camera = FakeTapoCamera();
      final result = await _login(camera).login(_password);
      expect(result.protocol, TapoLoginProtocol.v4);
      expect(result.passcode, TapoPasscodeHash.md5);
      expect(result.userName, TapoUserNameForm.md5);
      expect(camera.refusedShares, 0);
      final answer = await _deviceInfo(result.session);
      expect(_firstResult(answer)['method'], 'getDeviceInfo');
      expect(camera.calls, ['getDeviceInfo']);
      // The probe carried no password
      final probe = jsonDecode(utf8.decode(camera.bodies.first)) as Map;
      expect((probe['params'] as Map).keys, unorderedEquals(['cnonce', 'encrypt_type', 'username']));
    });

    test('numbers the requests from start_seq, one more each', () async {
      final camera = FakeTapoCamera(startSeq: 0x7fffffff);
      final result = await _login(camera).login(_password);
      for (var i = 0; i < 3; i++) {
        await _deviceInfo(result.session);
      }
      expect(camera.calls, hasLength(3));
      expect(camera.hasSession, isTrue);
    });

    test('tries the SHA-256 passcode after the md5 one, and the shadow of a C200', () async {
      final camera = FakeTapoCamera(passcode: TapoPasscodeHash.sha256, shadow: true);
      final result = await _login(camera).login(_password);
      expect(result.passcode, TapoPasscodeHash.sha256);
      expect(camera.shares, 2);
      expect(camera.refusedShares, 1);
      await _deviceInfo(result.session);
    });

    test('tries the user name forms that the camera refuses before any password', () async {
      final camera = FakeTapoCamera(userName: TapoUserNameForm.plain);
      final result = await _login(camera).login(_password);
      expect(result.userName, TapoUserNameForm.plain);
      expect(camera.registeredUserNames, [md5Hex('admin'), 'admin']);
      expect(camera.refusedShares, 0);

      final sha = FakeTapoCamera(userName: TapoUserNameForm.sha256);
      expect((await _login(sha).login(_password)).userName, TapoUserNameForm.sha256);
    });

    test('a wrong password costs two attempts at most on a first login, with the attempts left', () async {
      final camera = FakeTapoCamera(cloudPassword: 'another-password');
      final error = _refusal(
        await _login(camera).login(_password).then<Object>((_) => 'logged in', onError: (Object e) => e),
      );
      expect(error.kind, TapoErrorKind.wrongPassword);
      expect(error.attemptsLeft, 3);
      expect(camera.shares, 2);
    });

    test('a later login tries only the passcode that worked, once more after the pause', () async {
      final camera = FakeTapoCamera(passcode: TapoPasscodeHash.sha256)..refuseNextShares = 1;
      const known = TapoCameraInfo(
        protocol: TapoLoginProtocol.v4,
        passcode: TapoPasscodeHash.sha256,
        userName: TapoUserNameForm.md5,
      );
      final result = await _login(camera).login(_password, known: known);
      expect(result.passcode, TapoPasscodeHash.sha256);
      expect(camera.shares, 2);
      // Known to be V4: no probe
      expect(utf8.decode(camera.bodies.first), contains('pake_register'));

      final refusing = FakeTapoCamera(passcode: TapoPasscodeHash.sha256, cloudPassword: 'changed');
      await expectLater(
        _login(refusing).login(_password, known: known),
        throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)),
      );
      expect(refusing.shares, 2);
      expect(refusing.registeredUserNames, everyElement(md5Hex('admin')));
    });

    test('stops at a lockout, with its minutes', () async {
      final camera = FakeTapoCamera()
        ..lockout = {
          'error_code': -40404,
          'error_info': {'failedAttempts': 5, 'remainAttempts': 0, 'lockedMinute': 30},
        };
      await expectLater(
        _login(camera).login(_password),
        throwsA(
          isA<TapoCameraException>()
              .having((e) => e.kind, 'kind', TapoErrorKind.locked)
              .having((e) => e.lockedMinutes, 'minutes', 30),
        ),
      );
      expect(camera.shares, 0);
    });

    test('reads a lockout given as seconds left in data', () {
      final lockout = tapoLockoutOf({
        'error_code': -40401,
        'result': {
          'data': {'code': -40404, 'sec_left': 61},
        },
      });
      expect(lockout?.kind, TapoErrorKind.locked);
      expect(lockout?.lockedMinutes, 2);
      expect(tapoLockoutOf({'error_code': -40401}), isNull);
    });

    test('reads a lockedMinute as a lockout only with a lockout code or no attempt left', () {
      // The envelope of every refusal (P§4.1): the length a lock would have, while tries are left
      expect(
        tapoLockoutOf({
          'error_code': -40401,
          'error_info': {'failedAttempts': 1, 'remainAttempts': 4, 'lockedMinute': 30},
        }),
        isNull,
      );
      expect(
        tapoLockoutOf({
          'error_code': -40401,
          'error_info': {'failedAttempts': 5, 'remainAttempts': 0, 'lockedMinute': 30},
        })?.lockedMinutes,
        30,
      );
      expect(
        tapoLockoutOf({
          'error_code': -40408,
          'error_info': {'lockedMinute': 15},
        })?.lockedMinutes,
        15,
      );
    });

    test('a refusal that tells the length of a lock is a wrong password, and the second passcode is tried', () async {
      final camera = FakeTapoCamera(passcode: TapoPasscodeHash.sha256)..refusalLockedMinute = 30;
      final result = await _login(camera).login(_password);
      expect(result.passcode, TapoPasscodeHash.sha256);

      final refusing = FakeTapoCamera(cloudPassword: 'another')..refusalLockedMinute = 30;
      await expectLater(
        _login(refusing).login(_password),
        throwsA(
          isA<TapoCameraException>()
              .having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)
              .having((e) => e.attemptsLeft, 'attempts left', 3),
        ),
      );
    });

    test('refuses a huge iteration count before any password is involved', () async {
      final camera = FakeTapoCamera()..reportedIterations = 2000000000;
      await expectLater(
        _login(camera).login(_password),
        throwsA(
          isA<TapoCameraException>()
              .having((e) => e.kind, 'kind', TapoErrorKind.unsupported)
              .having((e) => e.detail, 'detail', 'pake_register'),
        ),
      );
      expect(camera.shares, 0);
    });

    test('gives up an exchange that takes too long, before any share is sent', () async {
      final camera = FakeTapoCamera();
      final login = TapoLogin(
        camera,
        spake2p: (input) => Completer<Spake2pOutput>().future,
        spake2pTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        login.login(_password),
        throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.unsupported)),
      );
      expect(camera.shares, 0);
    });

    test('tries the user name form the camera announced first, then the others', () async {
      final announced = FakeTapoCamera(userName: TapoUserNameForm.sha256);
      final result = await _login(announced).login(
        _password,
        known: const TapoCameraInfo(protocol: TapoLoginProtocol.v4, userName: TapoUserNameForm.sha256),
      );
      expect(result.userName, TapoUserNameForm.sha256);
      expect(announced.registeredUserNames, [sha256HexUpper('admin')]);

      // An announcement that does not hold: the other forms, which the camera refuses before any password
      final plain = FakeTapoCamera(userName: TapoUserNameForm.plain);
      final other = await _login(plain).login(
        _password,
        known: const TapoCameraInfo(protocol: TapoLoginProtocol.v4, userName: TapoUserNameForm.sha256),
      );
      expect(other.userName, TapoUserNameForm.plain);
      expect(plain.registeredUserNames, [sha256HexUpper('admin'), md5Hex('admin'), 'admin']);
      expect(plain.refusedShares, 0);
    });

    test('a camera announced as V4 never gets the V2 login', () async {
      final camera = FakeTapoCamera(protocol: TapoLoginProtocol.v2);
      await expectLater(
        _login(camera).login(_password, known: const TapoCameraInfo(protocol: TapoLoginProtocol.v4)),
        throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.unsupported)),
      );
      expect(camera.bodies.map(utf8.decode), everyElement(isNot(contains('hashed'))));
      expect(camera.logins, 0);
    });

    test('never sends an empty password', () async {
      final camera = FakeTapoCamera();
      await expectLater(
        _login(camera).login(''),
        throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)),
      );
      expect(camera.bodies, isEmpty);
    });

    test('a refused request ends the session and tells it as lost', () async {
      final camera = FakeTapoCamera();
      final result = await _login(camera).login(_password);
      camera.killSession();
      await expectLater(
        _deviceInfo(result.session),
        throwsA(isA<TapoSessionRefused>().having((e) => e.isSessionLost, 'lost', isTrue)),
      );
    });

    test('runs the exchange in an isolate by default', () async {
      final camera = FakeTapoCamera();
      final result = await TapoLogin(camera).login(_password);
      expect(result.protocol, TapoLoginProtocol.v4);
    });
  });

  group('V3', () {
    for (final passcode in TapoPasscodeHash.values) {
      test('logs in when the camera holds the ${passcode.name} of the password', () async {
        final camera = FakeTapoCamera(protocol: TapoLoginProtocol.v3, passcode: passcode);
        final result = await _login(camera).login(_password);
        expect(result.protocol, TapoLoginProtocol.v3);
        expect(result.passcode, passcode);
        final answer = await _deviceInfo(result.session);
        expect(_firstResult(answer)['method'], 'getDeviceInfo');
        await _deviceInfo(result.session);
        expect(camera.calls, hasLength(2));
      });
    }

    test('refuses a wrong password from the device confirmation, without a login attempt', () async {
      final camera = FakeTapoCamera(protocol: TapoLoginProtocol.v3, cloudPassword: 'another');
      await expectLater(
        _login(camera).login(_password),
        throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)),
      );
      expect(camera.bodies, hasLength(1));
    });

    test('refuses an account the camera was shared with', () async {
      final camera = FakeTapoCamera(protocol: TapoLoginProtocol.v3, userGroup: 'guest');
      await expectLater(
        _login(camera).login(_password),
        throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.notOwner)),
      );
    });
  });

  group('V2', () {
    test('logs in with the hashed password and sends plain JSON', () async {
      final camera = FakeTapoCamera(protocol: TapoLoginProtocol.v2);
      final result = await _login(camera).login(_password);
      expect(result.protocol, TapoLoginProtocol.v2);
      await _deviceInfo(result.session);
      expect(utf8.decode(camera.bodies.last), contains('multipleRequest'));
    });
  });
}
