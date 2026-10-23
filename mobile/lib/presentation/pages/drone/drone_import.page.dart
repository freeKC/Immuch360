// The DJI drone page of the Network shares (Android phones, Settings, Advanced, "DJI drones (experimental)", on by
// default): the photos and videos of a drone, its controller or a card plugged into the phone, picked in the system
// picker. By day, the newest first, with the proxies, the flight data and the sound recorded apart attached to their
// video, and the source shots of a sphere grouped with it. "Upload to Immich" sends them as from a share, "Keep on the
// device" copies them into the gallery.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/drone_import_grouping.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/platform/document_tree_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/drone_import.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_selection.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:logging/logging.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

final _log = Logger('DroneImportPage');

/// The selection of the page, one per picked folder
NetworkFolderKey droneSelectionKey(String sourceId) => (sourceId: sourceId, path: '/drone');

/// The icon of a kind of picked folder (see TreePick.kind)
IconData droneTreeIcon(String kind) => switch (kind) {
  'mtp' => Icons.phone_android_rounded,
  'internal' => Icons.smartphone_rounded,
  'usb' => Icons.usb_rounded,
  _ => Icons.folder_open_rounded,
};

String _kindLabel(Translations t, String kind) => switch (kind) {
  'mtp' => t.dji_import_kind_mtp,
  'internal' => t.dji_import_kind_internal,
  'usb' => t.dji_import_kind_usb,
  _ => t.dji_import_kind_other,
};

@RoutePage()
class DroneImportPage extends ConsumerStatefulWidget {
  const DroneImportPage({super.key});

  @override
  ConsumerState<DroneImportPage> createState() => _DroneImportPageState();
}

class _DroneImportPageState extends ConsumerState<DroneImportPage> {
  /// The spheres whose source shots are shown, by path
  final _expanded = <String>{};

  /// The photos read before the upload sheet opens: [done] of [total]; null when none is being read
  ({int done, int total})? _preparing;

  /// Kept from the start: the page tells it when it closes, when its ref is no longer usable
  late final DroneImportNotifier _droneNotifier;

  @override
  void initState() {
    super.initState();
    _droneNotifier = ref.read(droneImportProvider.notifier);
    // After the first frame: the notifier may change its state, which a build under way must not see
    unawaited(Future.microtask(() => _droneNotifier.pageShown(true)));
    try {
      // The places of drone videos that the server had not read in time (see VideoLocationService.retryPending)
      if (ref.read(hasServerProvider)) {
        unawaited(ref.read(videoLocationServiceProvider).retryPending());
      }
    } catch (error) {
      _log.fine('Could not go through the places waiting for the server: $error');
    }
  }

  @override
  void dispose() {
    _droneNotifier.pageShown(false);
    super.dispose();
  }

  DroneImportNotifier get _notifier => _droneNotifier;

  /// The photos and videos as the page shows them now, the sources of the spheres shown included
  List<DroneTileItem> _items(DroneDay day) => [
    for (final media in day.media) ...[
      DroneTileItem(entry: media.entry, media: media),
      if (_expanded.contains(media.entry.path))
        for (final source in media.sphereSources) DroneTileItem(entry: source, isSource: true),
    ],
  ];

  List<NetworkEntry> _shownEntries(DroneImportListing listing) => [
    for (final day in listing.days) ...[
      for (final item in _items(day)) item.entry,
      for (final group in day.unstitched) ...group.sources,
    ],
  ];

  void _open(DroneImportState state, NetworkEntry entry) {
    final sourceId = state.sourceId;
    final listing = state.listing;
    if (sourceId == null || listing == null) {
      return;
    }
    final key = droneSelectionKey(sourceId);
    if (ref.read(networkSelectionProvider(key)).isActive) {
      ref.read(networkSelectionProvider(key).notifier).toggle(entry.path);
      return;
    }
    final shown = _shownEntries(listing);
    final folder = NetworkFolderMedia(entries: shown, urls: state.urls, index: shown.indexOf(entry));
    unawaited(
      context.pushRoute(
        entry.isVideo
            ? NetworkVideoRoute(sourceId: sourceId, path: entry.path, folder: folder)
            : NetworkPhotoRoute(sourceId: sourceId, path: entry.path, folder: folder),
      ),
    );
  }

  void _select(String sourceId, NetworkEntry entry) {
    final key = droneSelectionKey(sourceId);
    final notifier = ref.read(networkSelectionProvider(key).notifier);
    if (ref.read(networkSelectionProvider(key)).isActive) {
      notifier.toggle(entry.path);
    } else {
      notifier.start(entry.path);
    }
  }

  void _selectNew(String sourceId, DroneImportListing listing) {
    final records = ref.read(networkUploadRecordsProvider);
    // A file whose asset sits in the Immich trash counts as new: the server will purge it
    final paths = droneNewFiles(listing, (entry) => isKeptOnServer(records[UploadRecordStore.keyOf(entry)]));
    ref.read(networkSelectionProvider(droneSelectionKey(sourceId)).notifier).replace(paths.map((entry) => entry.path));
  }

  List<NetworkEntry> _selected(DroneImportState state) {
    final sourceId = state.sourceId;
    final listing = state.listing;
    if (sourceId == null || listing == null) {
      return const [];
    }
    final selection = ref.read(networkSelectionProvider(droneSelectionKey(sourceId)));
    return listing.allMedia.where((entry) => selection.contains(entry.path)).toList();
  }

  Future<void> _upload(DroneImportState state) async {
    final sourceId = state.sourceId;
    final listing = state.listing;
    final entries = _selected(state);
    if (sourceId == null || listing == null || entries.isEmpty) {
      return;
    }
    ref.read(networkSelectionProvider(droneSelectionKey(sourceId)).notifier).end();
    // Read before the sheet, so that it offers the 360° tags of the spheres among the files: the head of each photo,
    // a few at a time, with the count on screen. Those not started after 20 s are dropped: the upload goes first.
    final media = ref.read(networkMediaServiceProvider);
    final photos = [
      for (final entry in entries)
        if (entry.isImage && media.cached(entry) == null) entry,
    ];
    if (photos.isNotEmpty) {
      var wanted = true;
      var done = 0;
      setState(() => _preparing = (done: 0, total: photos.length));
      try {
        final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(sourceId);
        await Future.wait([
          for (final entry in photos)
            media.detect(entry, networkFileReader(fileSystem, entry.path), isWanted: () => wanted).whenComplete(() {
              done++;
              if (mounted && wanted) {
                setState(() => _preparing = (done: done, total: photos.length));
              }
            }),
        ]).timeout(const Duration(seconds: 20));
      } catch (error) {
        _log.info('Could not read every photo before the upload: $error');
      } finally {
        wanted = false;
        if (mounted) {
          setState(() => _preparing = null);
        }
      }
    }
    if (!mounted) {
      return;
    }
    final byPath = listing.byPath;
    final hasFlightData = entries.any((entry) => byPath[entry.path]?.flightData != null);
    // A large video over USB takes minutes: the screen stays on meanwhile
    unawaited(WakelockPlus.enable());
    try {
      await uploadNetworkEntries(context, ref, sourceId, entries, alwaysAsk: true, hasFlightData: hasFlightData);
    } finally {
      unawaited(WakelockPlus.disable());
    }
  }

  Future<void> _keep(DroneImportState state) async {
    final sourceId = state.sourceId;
    final listing = state.listing;
    final entries = _selected(state);
    if (sourceId == null || listing == null || entries.isEmpty) {
      return;
    }
    final byPath = listing.byPath;
    final t = context.t;
    if (entries.any((entry) => byPath[entry.path]?.flightData != null)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => ConfirmDialog(
          title: t.dji_import_keep_on_device,
          content: t.dji_import_keep_loses_place,
          ok: t.dji_import_keep_on_device,
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    ref.read(networkSelectionProvider(droneSelectionKey(sourceId)).notifier).end();
    final messenger = ScaffoldMessenger.maybeOf(context);
    unawaited(WakelockPlus.enable());
    final DroneKeepSummary summary;
    try {
      summary = await _notifier.keep(entries);
    } finally {
      unawaited(WakelockPlus.disable());
    }
    final lastError = summary.lastError;
    final inGallery = summary.saved - summary.inDownloads;
    final parts = [
      if (inGallery > 0) t.dji_import_kept(count: inGallery, album: droneImportAlbum),
      if (summary.inDownloads > 0) t.dji_import_kept_downloads(count: summary.inDownloads, album: droneImportAlbum),
      if (summary.cancelled) t.network_upload_cancelled,
      if (summary.failed > 0 && lastError != null) t.network_upload_error(error: lastError),
    ];
    if (parts.isNotEmpty) {
      messenger?.showSnackBar(SnackBar(content: Text(parts.join(' · '))));
    }
  }

  void _showSoundNote() {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(context.t.dji_import_sound_apart), duration: const Duration(seconds: 8)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(droneImportProvider);
    final sourceId = state.sourceId;
    final selection = sourceId == null
        ? const NetworkSelection()
        : ref.watch(networkSelectionProvider(droneSelectionKey(sourceId)));
    final isUploading = ref.watch(networkUploadProvider.select((upload) => upload.isRunning));
    final keeping = state.keeping;
    final preparing = _preparing;

    return PopScope(
      canPop: !selection.isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && sourceId != null) {
          ref.read(networkSelectionProvider(droneSelectionKey(sourceId)).notifier).end();
        }
      },
      child: Scaffold(
        appBar: selection.isActive && sourceId != null
            ? _selectionAppBar(state, sourceId, selection)
            : AppBar(
                title: Text(context.t.dji_import_title),
                elevation: 0,
                centerTitle: false,
                actions: [
                  if (state.tree != null)
                    IconButton(
                      key: const Key('drone_import_refresh'),
                      icon: const Icon(Icons.refresh_rounded),
                      tooltip: context.t.refresh,
                      onPressed: () => unawaited(_notifier.refresh()),
                    ),
                  if (state.phase == DroneImportPhase.ready && sourceId != null && !(state.listing?.isEmpty ?? true))
                    IconButton(
                      key: const Key('drone_import_select'),
                      icon: const Icon(Icons.checklist_rounded),
                      tooltip: context.t.network_upload_select,
                      onPressed: () => ref.read(networkSelectionProvider(droneSelectionKey(sourceId)).notifier).start(),
                    ),
                ],
              ),
        bottomNavigationBar: isUploading
            ? const NetworkUploadProgressBar()
            : preparing != null
            ? _PreparingBar(done: preparing.done, total: preparing.total)
            : keeping != null
            ? _KeepProgressBar(progress: keeping, onCancel: _notifier.cancelKeep)
            : selection.isActive
            ? _SelectionBar(
                count: selection.paths.length,
                onUpload: () => unawaited(_upload(state)),
                onKeep: () => unawaited(_keep(state)),
              )
            : null,
        body: SafeArea(child: _body(state, selection)),
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar(DroneImportState state, String sourceId, NetworkSelection selection) {
    final notifier = ref.read(networkSelectionProvider(droneSelectionKey(sourceId)).notifier);
    final listing = state.listing;
    return AppBar(
      elevation: 0,
      centerTitle: false,
      leading: IconButton(icon: const Icon(Icons.close_rounded), tooltip: context.t.cancel, onPressed: notifier.end),
      title: Text(context.t.network_upload_selected(count: selection.paths.length)),
      actions: [
        if (listing != null) ...[
          TextButton(
            key: const Key('drone_import_select_new'),
            onPressed: () => _selectNew(sourceId, listing),
            child: Text(context.t.dji_import_select_new),
          ),
          IconButton(
            icon: const Icon(Icons.select_all_rounded),
            tooltip: context.t.network_upload_select_all,
            onPressed: () => notifier.toggleAll(_shownEntries(listing).map((entry) => entry.path)),
          ),
        ],
      ],
    );
  }

  Widget _body(DroneImportState state, NetworkSelection selection) {
    final tree = state.tree;
    if (tree == null) {
      return _PlugInView(state: state, notifier: _notifier);
    }
    switch (state.phase) {
      case DroneImportPhase.choosing:
        return _PlugInView(state: state, notifier: _notifier);
      case DroneImportPhase.reading:
        if (state.listing == null) {
          return NetworkLoadingView(message: context.t.dji_import_reading(name: tree.title));
        }
      case DroneImportPhase.unplugged:
        return _UnpluggedView(tree: tree, notifier: _notifier);
      case DroneImportPhase.ready:
        break;
    }
    final listing = state.listing;
    if (listing == null) {
      return NetworkErrorView(error: state.error ?? 'unknown error', onRetry: () => unawaited(_notifier.refresh()));
    }
    final sourceId = state.sourceId!;
    return RefreshIndicator(
      onRefresh: _notifier.refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _TreeHeader(tree: tree, onChange: () => unawaited(_notifier.closeTree())),
          ),
          if (state.incomplete)
            SliverToBoxAdapter(child: _IncompleteNote(onRefresh: () => unawaited(_notifier.refresh()))),
          if (listing.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(context.t.dji_import_empty, textAlign: TextAlign.center),
                ),
              ),
            ),
          for (final day in listing.days) ...[
            SliverToBoxAdapter(child: _DayHeader(day: day.day)),
            _grid(state, sourceId, selection, _items(day)),
            for (final group in day.unstitched) ...[
              SliverToBoxAdapter(
                child: Padding(
                  key: Key('drone_import_unstitched_${group.folder}'),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    context.t.dji_import_sources_unstitched,
                    style: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              _grid(state, sourceId, selection, [
                for (final source in group.sources) DroneTileItem(entry: source, isSource: true),
              ]),
            ],
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _grid(DroneImportState state, String sourceId, NetworkSelection selection, List<DroneTileItem> items) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final media = item.media;
          final path = item.entry.path;
          final frameUrl = state.frameUrls[path];
          // On a device that sends files from their start only, a frame of a video without proxy would cost a read
          // of the whole video: a plain video tile
          final noFrame = state.readsFromStartOnly && item.entry.isVideo && frameUrl == null;
          return DroneMediaTile(
            key: ValueKey(path),
            item: item,
            url: noFrame ? null : state.urls[path],
            frameUrl: frameUrl,
            isSelected: selection.isActive ? selection.contains(path) : null,
            sourcesShown: _expanded.contains(path),
            onTap: () => _open(state, item.entry),
            onLongPress: () => _select(sourceId, item.entry),
            onToggleSources: media == null || media.sphereSources.isEmpty
                ? null
                : () => setState(() => _expanded.contains(path) ? _expanded.remove(path) : _expanded.add(path)),
            onSoundNote: _showSoundNote,
          );
        },
      ),
    );
  }
}

/// Nothing open: how to plug in, the button that opens the picker, and the folders picked before. While it shows, the
/// accessory list of the system is read every [_remotePollInterval] and when the app comes back, because Android
/// delivers no broadcast for an accessory to a page that is not its owner: a DJI remote plugged in by mistake gets a card
/// saying that it holds no photos, with a way to the DJI link page when that switch is on. Reading the list needs no
/// permission and opens nothing, so it takes the remote from neither the link page nor DJI Fly.
class _PlugInView extends ConsumerStatefulWidget {
  const _PlugInView({required this.state, required this.notifier});

  final DroneImportState state;
  final DroneImportNotifier notifier;

  @override
  ConsumerState<_PlugInView> createState() => _PlugInViewState();
}

const _remotePollInterval = Duration(seconds: 2);

class _PlugInViewState extends ConsumerState<_PlugInView> with WidgetsBindingObserver {
  Timer? _poll;
  bool _remotePlugged = false;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(Future.microtask(_lookForRemote));
    _poll = Timer.periodic(_remotePollInterval, (_) => unawaited(_lookForRemote()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_lookForRemote());
    }
  }

  Future<void> _lookForRemote() async {
    if (_asking || !mounted) {
      return;
    }
    _asking = true;
    try {
      final listed = await ref.read(djiPluggedAccessoriesProvider)();
      final plugged = listed.any(_isDjiRemote);
      if (mounted && plugged != _remotePlugged) {
        setState(() => _remotePlugged = plugged);
      }
    } finally {
      _asking = false;
    }
  }

  static bool _isDjiRemote(DjiLinkPluggedAccessory accessory) => accessory.manufacturer?.trim().toUpperCase() == 'DJI';

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = widget.state;
    final notifier = widget.notifier;
    final muted = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 24),
      children: [
        Icon(Icons.usb_rounded, size: 72, color: context.primaryColor),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 8),
          child: Text(t.dji_import_plug_in, textAlign: TextAlign.center, style: context.textTheme.bodyLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
          child: Text(t.dji_import_choose_help, textAlign: TextAlign.center, style: muted),
        ),
        if (_remotePlugged)
          Card(
            key: const Key('drone_import_remote_plugged'),
            margin: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.settings_remote_rounded, color: context.primaryColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t.dji_import_remote_plugged,
                          style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(t.dji_import_remote_no_files, style: context.textTheme.bodyMedium),
                  if (ref.watch(djiLinkEnabledProvider))
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const Key('drone_import_open_link'),
                        onPressed: () => unawaited(context.pushRoute(const DjiLinkRoute())),
                        child: Text(t.dji_import_open_link),
                      ),
                    ),
                ],
              ),
            ),
          ),
        Center(
          child: FilledButton.icon(
            key: const Key('drone_import_choose'),
            icon: const Icon(Icons.folder_open_rounded),
            label: Text(t.dji_import_choose),
            onPressed: () => unawaited(notifier.choose()),
          ),
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
            child: Text(
              networkErrorMessage(state.error!),
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colorScheme.error),
            ),
          ),
        if (state.recents.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 4),
            child: Text(
              t.dji_import_recent,
              style: context.textTheme.titleSmall?.copyWith(color: context.primaryColor, fontWeight: FontWeight.bold),
            ),
          ),
          for (final recent in state.recents)
            ListTile(
              key: Key('drone_import_recent_${recent.treeUri}'),
              contentPadding: const EdgeInsets.only(left: 20, right: 8),
              leading: Icon(droneTreeIcon(recent.kind), color: context.primaryColor),
              title: Text(
                recent.title == recent.folderName ? recent.title : '${recent.title}, ${recent.folderName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                state.missing.contains(recent.treeUri) ? t.dji_import_not_plugged : _kindLabel(t, recent.kind),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: t.dji_import_forget,
                onPressed: () => unawaited(notifier.forget(recent)),
              ),
              onTap: () => unawaited(notifier.openRecent(recent)),
            ),
        ],
      ],
    );
  }
}

/// The folder open stopped answering
class _UnpluggedView extends StatelessWidget {
  const _UnpluggedView({required this.tree, required this.notifier});

  final TreePick tree;
  final DroneImportNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.usb_off_rounded, size: 72, color: context.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              context.t.dji_import_unplugged,
              key: const Key('drone_import_unplugged'),
              textAlign: TextAlign.center,
              style: context.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(tree.title, style: context.textTheme.bodyMedium),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(onPressed: () => unawaited(notifier.refresh()), child: Text(context.t.refresh)),
                OutlinedButton(
                  onPressed: () => unawaited(notifier.closeTree()),
                  child: Text(context.t.dji_import_choose_other),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The folder open, where it is, and the button to choose another
class _TreeHeader extends StatelessWidget {
  const _TreeHeader({required this.tree, required this.onChange});

  final TreePick tree;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const Key('drone_import_tree'),
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      leading: Icon(droneTreeIcon(tree.kind), color: context.primaryColor),
      title: Text(tree.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        context.t.dji_import_tree_subtitle(kind: _kindLabel(context.t, tree.kind), folder: tree.folderName),
        maxLines: 1,
      ),
      trailing: TextButton(onPressed: onChange, child: Text(context.t.dji_import_choose_other)),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final locale = context.locale.toLanguageTag();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        DateFormat.yMMMMEEEEd(locale).format(day),
        style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The device was still sending its list of files, or a folder could not be listed: files may be missing
class _IncompleteNote extends StatelessWidget {
  const _IncompleteNote({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('drone_import_incomplete'),
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: context.colorScheme.error, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.t.dji_import_still_listing,
              style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.error),
            ),
          ),
          TextButton(onPressed: onRefresh, child: Text(context.t.refresh)),
        ],
      ),
    );
  }
}

/// The photos read before the upload sheet opens
class _PreparingBar extends StatelessWidget {
  const _PreparingBar({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('drone_import_preparing'),
      color: context.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: total == 0 ? null : done / total),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                context.t.dji_import_preparing(done: done, total: total),
                style: context.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// At the bottom while picking files: send them to Immich, or keep them on the device
class _SelectionBar extends ConsumerWidget {
  const _SelectionBar({required this.count, required this.onUpload, required this.onKeep});

  final int count;
  final VoidCallback onUpload;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasServer = ref.watch(hasServerProvider);
    return Material(
      color: context.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('drone_import_keep'),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(context.t.dji_import_keep_on_device, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onPressed: count > 0 ? onKeep : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('drone_import_upload'),
                  icon: const Icon(Icons.backup_outlined),
                  label: Text(context.t.network_upload_action, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onPressed: count > 0 && hasServer ? onUpload : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The copies into the gallery under way, with their cancel button
class _KeepProgressBar extends StatelessWidget {
  const _KeepProgressBar({required this.progress, required this.onCancel});

  final DroneKeepProgress progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final fileFraction = progress.fileBytes > 0 ? progress.bytes / progress.fileBytes : 0.0;
    final fraction = progress.total == 0 ? 0.0 : ((progress.done + fileFraction) / progress.total).clamp(0.0, 1.0);
    return Material(
      key: const Key('drone_import_keeping'),
      color: context.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: fraction),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${context.t.dji_import_keeping(done: progress.done + 1, total: progress.total)}'
                      '${progress.fileBytes > 0 ? ' · ${formatHumanReadableBytes(progress.fileBytes, 1)}' : ''}',
                      style: context.textTheme.titleSmall,
                    ),
                  ),
                  TextButton(onPressed: onCancel, child: Text(context.t.cancel)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
