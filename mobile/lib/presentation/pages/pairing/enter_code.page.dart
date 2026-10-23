// "Enter a code instead": the screens that wait for a phone nearby (DNS-SD, _immuch360-pair._tcp), or the address
// shown under the code, and the 10 symbols of the code. The natural path on the Quest, whose window no phone camera
// can see, when the camera is refused, and after a link of a screen (its address filled in). Pops the target of the
// pairing; the Connect page runs it as a scanned one.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_confirm.sheet.dart';
import 'package:immich_mobile/providers/pairing/phone_pairing.provider.dart';
import 'package:immich_ui/immich_ui.dart';

/// The services announced nearby under a DNS-SD type, until the future completes; tests replace it
final pairingBrowseProvider = Provider<Stream<MdnsService> Function(String type, Future<void> until)>(
  (_) => bonsoirBrowse,
);

/// A screen announced nearby
class _FoundScreen {
  const _FoundScreen({required this.name, required this.host, required this.port, required this.kind});

  final String name;
  final String host;
  final int port;
  final PairingScreenKind kind;

  String get key => '$host:$port';
}

@RoutePage()
class EnterCodePage extends ConsumerStatefulWidget {
  const EnterCodePage({super.key, this.address});

  /// The address of the screen a link named ("192.168.1.23:8361"), filled in
  final String? address;

  @override
  ConsumerState<EnterCodePage> createState() => _EnterCodePageState();
}

class _EnterCodePageState extends ConsumerState<EnterCodePage> {
  final _found = <_FoundScreen>[];
  final _address = TextEditingController();
  final _code = TextEditingController();
  final _browsing = Completer<void>();
  StreamSubscription<MdnsService>? _discovery;
  String? _selected;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _address.text = widget.address ?? '';
    // Looked for as long as the page shows, two minutes at most: the life of a code
    _discovery = ref.read(pairingBrowseProvider)(
      pairingServiceType,
      Future.any([_browsing.future, Future<void>.delayed(const Duration(minutes: 2))]),
    ).listen((service) => unawaited(_add(service)), onError: (Object _) {});
  }

  @override
  void dispose() {
    if (!_browsing.isCompleted) {
      _browsing.complete();
    }
    unawaited(_discovery?.cancel());
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _add(MdnsService service) async {
    // A phone that sends a drone's picture to headsets (DJI link) announces itself under the same type: not a screen
    if (service.attributes['kind'] == 'drone') {
      return;
    }
    final host = isPrivatePairingIPv4(service.host) ? service.host : await lookupIPv4(service.host);
    if (host == null || !isPrivatePairingIPv4(host) || !mounted) {
      return;
    }
    final screen = _FoundScreen(
      name: cleanPairingText(service.name),
      host: host,
      port: service.port,
      kind: PairingScreenKind.fromWire(service.attributes['kind']),
    );
    if (_found.any((other) => other.key == screen.key)) {
      return;
    }
    setState(() {
      _found.add(screen);
      // The one screen found is the one, unless a link named another
      final linked = widget.address;
      if (linked == null) {
        _selected ??= screen.key;
      } else if (screen.key == linked) {
        _selected = screen.key;
      }
    });
  }

  Future<void> _continue() async {
    final t = context.t;
    final code = normalizePairingCode(_code.text);
    if (code == null) {
      return setState(() => _error = t.pairing_err_wrong_code);
    }
    ({String host, int port})? address;
    final selected = _found.where((screen) => screen.key == _selected).firstOrNull;
    if (selected != null) {
      address = (host: selected.host, port: selected.port);
    } else {
      address = parsePairingAddress(_address.text);
    }
    if (address == null) {
      return setState(() => _error = t.pairing_err_bad_address);
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final info = await ref.read(phonePairingServiceProvider).info(host: address.host, port: address.port);
      final id = info.id;
      if (!mounted) {
        return;
      }
      if (id == null) {
        return setState(() => _error = t.pairing_err_expired);
      }
      await context.maybePop(PairingTarget(host: address.host, port: address.port, id: id, code: code));
    } on PairingException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.failure == PairingFailure.unreachable
              ? t.pairing_err_unreachable(address: address!.host)
              : t.pairing_err_screen_answer,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final typed = _found.isEmpty || _selected == null;
    return Scaffold(
      appBar: AppBar(title: Text(t.pairing_enter_code_title)),
      body: ListView(
        padding: const EdgeInsets.all(ImmichSpacing.lg),
        children: [
          Text(t.pairing_enter_code_screens, style: theme.titleMedium),
          const SizedBox(height: ImmichSpacing.sm),
          if (_found.isEmpty)
            Text(t.pairing_enter_code_none_found, style: theme.bodyMedium)
          else
            RadioGroup<String>(
              groupValue: _selected,
              onChanged: (value) => setState(() => _selected = value),
              child: Column(
                children: [
                  for (final screen in _found)
                    RadioListTile<String>(
                      key: ValueKey('pairing_found_${screen.key}'),
                      value: screen.key,
                      title: Text(screen.name),
                      subtitle: Text(screen.host),
                      secondary: Icon(pairingKindIcon(screen.kind)),
                    ),
                ],
              ),
            ),
          if (_found.isNotEmpty && !typed)
            TextButton(onPressed: () => setState(() => _selected = null), child: Text(t.pairing_enter_code_address)),
          if (typed) ...[
            const SizedBox(height: ImmichSpacing.md),
            TextField(
              key: const Key('pairing_address'),
              controller: _address,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: t.pairing_enter_code_address,
                hintText: 'http://192.168.1.23:8361/p',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: ImmichSpacing.md),
          TextField(
            key: const Key('pairing_code_field'),
            controller: _code,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [LengthLimitingTextInputFormatter(14)],
            style: const TextStyle(fontFamily: 'GoogleSansCode', fontSize: 22, letterSpacing: 2),
            decoration: InputDecoration(
              labelText: t.pairing_enter_code_code,
              hintText: 'K7M2Q 9XRTH',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => unawaited(_continue()),
          ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: ImmichSpacing.sm),
              child: Text(
                error,
                key: const Key('pairing_code_error'),
                style: TextStyle(color: context.colorScheme.error),
              ),
            ),
          const SizedBox(height: ImmichSpacing.lg),
          FilledButton(
            key: const Key('pairing_code_continue'),
            onPressed: _busy ? null : () => unawaited(_continue()),
            child: _busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(t.next),
          ),
        ],
      ),
    );
  }
}
