// "Network for discovery and sharing", in the "This computer" settings: the network adapter the user picks when the
// automatic choice of interface_rank.dart uses the wrong one (a LAN behind a virtual switch, two networks at once).
// Kept in desktop_network.json in the app's support folder, outside the main database, whose schema stays the phones'.
// Automatic (no file, or no adapter in it) is the default.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/network/interface_rank.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('DesktopNetworkChoice');

abstract final class DesktopNetworkChoice {
  static const fileName = 'desktop_network.json';

  /// Where the file lives; a temporary folder in the tests
  @visibleForTesting
  static Future<Directory> Function() folder = getApplicationSupportDirectory;

  static String? _chosen;
  static Future<String?>? _loaded;

  /// The adapter chosen by the user, null for Automatic. Read from the file once, then kept.
  static Future<String?> load() => _loaded ??= _read();

  /// Keeps [adapter] (null for Automatic) for discovery and sharing, from now on and at the next starts
  static Future<void> save(String? adapter) async {
    final chosen = adapter == null || adapter.trim().isEmpty ? null : adapter;
    _chosen = chosen;
    _loaded = Future.value(chosen);
    try {
      final file = File(p.join((await folder()).path, fileName));
      await file.parent.create(recursive: true);
      // Written beside, then renamed over: a crash in the middle leaves the previous choice, not half a file
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode({'adapter': chosen}), flush: true);
      await temporary.rename(file.path);
    } catch (error) {
      _log.warning('The network choice is kept for this session only: $error');
    }
  }

  @visibleForTesting
  static void forget() {
    _chosen = null;
    _loaded = null;
  }

  static Future<String?> _read() async {
    try {
      final file = File(p.join((await folder()).path, fileName));
      if (!file.existsSync()) {
        return _chosen;
      }
      final content = jsonDecode(await file.readAsString());
      final adapter = content is Map ? content['adapter'] : null;
      return _chosen = adapter is String && adapter.isNotEmpty ? adapter : null;
    } catch (error) {
      // A damaged file is Automatic, which works on most computers, rather than an error at every scan
      _log.warning('The network choice could not be read, automatic choice instead: $error');
      return _chosen;
    }
  }
}

/// The tile of the "This computer" settings: the adapter used for discovery and sharing, or Automatic, and a dialog to
/// change it
class DesktopNetworkAdapterTile extends StatefulWidget {
  const DesktopNetworkAdapterTile({super.key, this.choices = desktopAdapterChoices});

  /// The interfaces offered, as (name, address); the system's in the app
  final Future<List<(String, String)>> Function() choices;

  @override
  State<DesktopNetworkAdapterTile> createState() => _DesktopNetworkAdapterTileState();
}

class _DesktopNetworkAdapterTileState extends State<DesktopNetworkAdapterTile> {
  String? _chosen;

  @override
  void initState() {
    super.initState();
    unawaited(
      DesktopNetworkChoice.load().then((chosen) {
        if (mounted) {
          setState(() => _chosen = chosen);
        }
      }),
    );
  }

  Future<void> _change() async {
    final picked = await showDialog<_Pick>(
      context: context,
      builder: (context) => _AdapterDialog(current: _chosen, choices: widget.choices),
    );
    if (picked == null || !mounted) {
      return;
    }
    await DesktopNetworkChoice.save(picked.adapter);
    if (mounted) {
      setState(() => _chosen = picked.adapter);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ListTile(
      key: const Key('desktop_network_adapter'),
      leading: const Icon(Icons.lan_outlined),
      title: Text(t.desktop_network_adapter),
      subtitle: Text(_chosen ?? t.desktop_network_adapter_automatic),
      onTap: () => unawaited(_change()),
    );
  }
}

/// What the dialog gives back: an adapter, or null for Automatic
class _Pick {
  const _Pick(this.adapter);

  final String? adapter;
}

class _AdapterDialog extends StatefulWidget {
  const _AdapterDialog({required this.current, required this.choices});

  final String? current;
  final Future<List<(String, String)>> Function() choices;

  @override
  State<_AdapterDialog> createState() => _AdapterDialogState();
}

class _AdapterDialogState extends State<_AdapterDialog> {
  late final Future<List<(String, String)>> _choices = widget.choices();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Radio values must not be null: the empty name stands for Automatic, which no adapter has
    const automatic = '';
    return SimpleDialog(
      title: Text(t.desktop_network_adapter),
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(t.desktop_network_adapter_subtitle)),
        FutureBuilder<List<(String, String)>>(
          future: _choices,
          builder: (context, snapshot) {
            final choices = snapshot.data;
            if (choices == null) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            // A chosen adapter that is not connected now stays shown, so that it can be seen and changed
            final current = widget.current;
            final names = [
              for (final (name, _) in choices) name,
              if (current != null && !choices.any((choice) => choice.$1 == current)) current,
            ];
            final addressOf = {for (final (name, address) in choices) name: address};
            return RadioGroup<String>(
              groupValue: current ?? automatic,
              onChanged: (value) => Navigator.of(context).pop(_Pick(value == null || value.isEmpty ? null : value)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<String>(
                    key: const Key('desktop_network_adapter_automatic'),
                    value: automatic,
                    title: Text(t.desktop_network_adapter_automatic),
                  ),
                  for (final name in names)
                    RadioListTile<String>(
                      value: name,
                      title: Text(name),
                      subtitle: addressOf[name] == null ? null : Text(addressOf[name]!),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
