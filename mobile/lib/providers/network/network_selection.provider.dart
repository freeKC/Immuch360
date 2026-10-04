// The photos and videos picked in a folder of the network share browser, to send them to the Immich server

import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A folder of a share in the browser
typedef NetworkFolderKey = ({String sourceId, String path});

/// Whether the browser of a folder is picking files, and the paths of those picked
class NetworkSelection {
  const NetworkSelection({this.isActive = false, this.paths = const {}});

  final bool isActive;
  final Set<String> paths;

  bool contains(String path) => paths.contains(path);
}

class NetworkSelectionNotifier extends AutoDisposeFamilyNotifier<NetworkSelection, NetworkFolderKey> {
  @override
  NetworkSelection build(NetworkFolderKey arg) => const NetworkSelection();

  /// Starts picking, with the file at [path] picked when given (a long press on it)
  void start([String? path]) {
    state = NetworkSelection(isActive: true, paths: {...state.paths, ?path});
  }

  /// Picks the file at [path], or leaves it out when it was picked
  void toggle(String path) {
    final paths = {...state.paths};
    if (!paths.remove(path)) {
      paths.add(path);
    }
    state = NetworkSelection(isActive: true, paths: paths);
  }

  /// Picks every file of [paths], or none when they all were already
  void toggleAll(Iterable<String> paths) {
    final all = paths.toSet();
    state = NetworkSelection(isActive: true, paths: state.paths.containsAll(all) ? const {} : all);
  }

  /// Stops picking
  void end() {
    state = const NetworkSelection();
  }
}

final networkSelectionProvider = NotifierProvider.autoDispose
    .family<NetworkSelectionNotifier, NetworkSelection, NetworkFolderKey>(NetworkSelectionNotifier.new);
