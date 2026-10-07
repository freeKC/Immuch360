// The names of the entries of the shares whose server knows its media by id rather than by path (the DLNA media
// servers, Plex): the browser, the bridge and the upload records address files by path, so each entry gets a name
// that a path can hold, unique in its folder.

final _unsafeNameCharacters = RegExp(r'[/\\\x00-\x1F\x7F]');

/// [name] trimmed, with the characters a path cannot hold (slashes, control characters) replaced by "_"; "_" for an
/// empty name, "." and "..", which would point to another folder
String safeEntryName(String name) {
  final safe = name.trim().replaceAll(_unsafeNameCharacters, '_');
  return safe.isEmpty || safe == '.' || safe == '..' ? '_' : safe;
}

/// The [items] of one listing that have a name ([nameOf] gives null for the others), in their order, the names made
/// unique without case: the second "a.jpg" becomes "a (2).jpg", then "a (3).jpg". The number goes before the extension
/// of a file and at the end of a folder name, whose dot is no extension.
List<({T item, String name})> uniqueEntryNames<T>(
  Iterable<T> items,
  String? Function(T item) nameOf,
  bool Function(T item) isFolder,
) {
  final taken = <String>{};
  final named = <({T item, String name})>[];
  for (final item in items) {
    final name = nameOf(item);
    if (name == null) {
      continue;
    }
    var unique = name;
    if (!taken.add(name.toLowerCase())) {
      final dot = isFolder(item) ? -1 : name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final extension = dot > 0 ? name.substring(dot) : '';
      for (var n = 2; ; n++) {
        unique = '$stem ($n)$extension';
        if (taken.add(unique.toLowerCase())) {
          break;
        }
      }
    }
    named.add((item: item, name: unique));
  }
  return named;
}
