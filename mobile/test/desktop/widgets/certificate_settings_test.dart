// The certificate settings of the computers: the "Trusted certificates" group of "This computer", and the import of
// the client certificate from a file with its password, which replaces the Android system picker. The file dialogs
// are replaced by functions answering a fixture or nothing.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/client_certificate_import.dart';
import 'package:immich_mobile/desktop/network/trusted_certificates.dart';
import 'package:immich_mobile/desktop/network/trusted_certificates_settings.dart';
import 'package:immich_mobile/desktop/platform/desktop_network_api.dart';
import 'package:immich_mobile/platform/network_api.g.dart';

import '../../widget_tester_extensions.dart';

final _authority = File('test/desktop/network/fixtures/test_authority.pem').readAsBytesSync();

/// The list without its files, which trusted_certificates and tls_contract tests cover
class _MemoryCertificates extends TrustedCertificates {
  List<TrustedCertificate> _list = const [];

  @override
  List<TrustedCertificate> get certificates => _list;

  @override
  Future<List<TrustedCertificate>> add(List<int> fileBytes) async {
    final read = readCertificates(fileBytes);
    if (read.isEmpty) {
      throw const FormatException('No certificate in this file');
    }
    _list = [..._list, ...read];
    notifyListeners();
    return read;
  }

  @override
  Future<void> remove(TrustedCertificate certificate) async {
    _list = [
      for (final kept in _list)
        if (kept != certificate) kept,
    ];
    notifyListeners();
  }
}

class _RecordingNetworkApi extends DesktopNetworkApi {
  ClientCertData? received;

  @override
  Future<void> addCertificate(ClientCertData clientData) async => received = clientData;
}

/// The widget of type [T] holding the keyboard focus
T? _focused<T extends Widget>() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<T>();

/// The label of the text button holding the keyboard focus
String? _focusedText() => switch (_focused<TextButton>()?.child) {
  Text(:final data) => data,
  _ => null,
};

void main() {
  test('the fixture reads as the certificate it is', () {
    final certificate = readCertificates(_authority).single;
    expect(certificate.subject, 'Immuch360 Test Authority');
    // After 2049 X.509 dates are GeneralizedTime
    expect(certificate.notAfter, DateTime.utc(2126, 9, 13, 23, 46, 51));
    expect(
      certificate.displayFingerprint,
      'F2:48:24:7E:BB:29:C4:D7:7B:DA:94:49:9F:71:7B:8D:3D:BC:38:E7:17:63:D1:76:81:54:3E:1A:AE:BA:66:CC',
    );
  });

  group('TrustedCertificatesSettings', () {
    testWidgets('lists, adds and removes the certificates', (tester) async {
      final certificates = _MemoryCertificates();
      var picked = Uint8List.fromList(_authority);
      // The settings pages are scaffolds, where the error shows as a snack bar
      await tester.pumpConsumerWidget(
        Scaffold(
          body: SingleChildScrollView(
            child: TrustedCertificatesSettings(certificates: certificates, pickFile: () async => picked),
          ),
        ),
      );
      expect(find.text('Trusted certificates'), findsOneWidget);
      expect(find.text('No certificate added'), findsOneWidget);

      await tester.tap(find.byKey(const Key('desktop_trusted_certificates_add')));
      await tester.pumpAndSettle();
      expect(find.text('No certificate added'), findsNothing);
      expect(find.text('Immuch360 Test Authority'), findsOneWidget);
      expect(find.textContaining('F2:48:24:7E'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('No certificate added'), findsOneWidget);

      picked = Uint8List.fromList('no certificate'.codeUnits);
      await tester.tap(find.byKey(const Key('desktop_trusted_certificates_add')));
      await tester.pumpAndSettle();
      expect(find.text('This file holds no PEM certificate'), findsOneWidget);
      expect(certificates.certificates, isEmpty);
    });

    testWidgets('labels for screen readers, and Tab from each remove button to the add entry', (tester) async {
      final semantics = tester.ensureSemantics();
      final certificates = _MemoryCertificates();
      await certificates.add(_authority);
      await tester.pumpConsumerWidget(
        SingleChildScrollView(
          child: TrustedCertificatesSettings(certificates: certificates, pickFile: () async => null),
        ),
      );
      // The remove button is read after the certificate's name, as its tooltip
      expect(tester.getSemantics(find.byType(IconButton)), isSemantics(tooltip: 'Remove', isButton: true));
      expect(find.bySemanticsLabel(RegExp('Immuch360 Test Authority')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Add a certificate')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused<IconButton>()?.tooltip, 'Remove');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focused<ListTile>()?.key, const Key('desktop_trusted_certificates_add'));
      semantics.dispose();
    });

    testWidgets('giving up the file dialog changes nothing', (tester) async {
      final certificates = _MemoryCertificates();
      await tester.pumpConsumerWidget(
        SingleChildScrollView(
          child: TrustedCertificatesSettings(certificates: certificates, pickFile: () async => null),
        ),
      );
      await tester.tap(find.byKey(const Key('desktop_trusted_certificates_add')));
      await tester.pumpAndSettle();
      expect(find.text('No certificate added'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('importClientCertificate', () {
    final prompt = ClientCertPrompt(
      title: 'Certificate Password',
      message: 'Enter the password for this certificate',
      cancel: 'Cancel',
      confirm: 'Confirm',
    );

    Future<Object?> run(WidgetTester tester, {required Uint8List? file, String? password, NetworkApi? api}) async {
      Object? outcome = 'running';
      await tester.pumpConsumerWidget(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => importClientCertificate(context, prompt, pickFile: () async => file, api: api).then<void>(
              (_) {
                outcome = null;
              },
              onError: (Object error) {
                outcome = error;
              },
            ),
            child: const Text('import'),
          ),
        ),
      );
      await tester.tap(find.text('import'));
      await tester.pumpAndSettle();
      if (file != null) {
        expect(find.text('Enter the password for this certificate'), findsOneWidget);
        if (password == null) {
          await tester.tap(find.text('Cancel'));
        } else {
          await tester.enterText(find.byKey(const Key('client_certificate_password')), password);
          await tester.tap(find.text('Confirm'));
        }
        await tester.pumpAndSettle();
      }
      return outcome;
    }

    testWidgets('the file and its password go to NetworkApi.addCertificate', (tester) async {
      final api = _RecordingNetworkApi();
      final file = Uint8List.fromList([1, 2, 3]);
      expect(await run(tester, file: file, password: 'secret', api: api), isNull);
      expect(api.received?.data, file);
      expect(api.received?.password, 'secret');
    });

    testWidgets('the password field has the focus and its label, then Tab goes to cancel and confirm', (tester) async {
      await tester.pumpConsumerWidget(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => importClientCertificate(
              context,
              prompt,
              pickFile: () async => Uint8List.fromList([1]),
              api: _RecordingNetworkApi(),
            ).catchError((Object _) {}),
            child: const Text('import'),
          ),
        ),
      );
      await tester.tap(find.text('import'));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('client_certificate_password'));
      expect(tester.widget<TextField>(field).decoration?.labelText, 'Certificate Password');
      expect(_focused<TextField>()?.key, const Key('client_certificate_password'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedText(), 'Cancel');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusedText(), 'Confirm');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('no file, or no password: cancelled, as the phone pickers end', (tester) async {
      final api = _RecordingNetworkApi();
      for (final file in [
        null,
        Uint8List.fromList([1]),
      ]) {
        final outcome = await run(tester, file: file, api: api);
        expect(outcome, isA<PlatformException>().having((e) => e.code, 'code', contains('cancel')));
      }
      expect(api.received, isNull);
    });
  });
}
