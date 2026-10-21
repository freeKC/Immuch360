import 'package:pigeon/pigeon.dart';

// Android phones only: a folder picked in the system picker (ACTION_OPEN_DOCUMENT_TREE), read through the Storage
// Access Framework. It reaches a DJI drone or a card reader plugged in over USB (a USB drive, served by
// ExternalStorageProvider) and a DJI RC 2 or another phone set to "File transfer" (MTP, served by MtpDocumentsProvider),
// with no permission: the picker grants access to the folder chosen. The DJI drone page of the Network shares reads it
// as a share (see DocumentTreeFileSystem). Not on iOS nor the computers: the page is not offered there.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/document_tree_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/documenttree/DocumentTree.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.documenttree'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// A folder picked in the system picker, or found again from an earlier pick
class TreePick {
  const TreePick({required this.treeUri, required this.title, required this.folderName, required this.kind});

  /// The tree URI the picker gave, with a persisted read grant when the provider allows one
  final String treeUri;

  /// The name of the volume or the device it is on, as the picker shows it ("USB drive", "DJI RC 2", "SanDisk")
  final String title;

  /// The name of the folder picked ("DCIM", or the volume itself)
  final String folderName;

  /// Where it is: "usb" (a USB drive or an SD card), "mtp" (a device in File transfer mode), "internal" (the storage
  /// of the phone), "other"
  final String kind;
}

/// A file or a folder of a picked tree, as one query of its folder lists it
class DocEntry {
  const DocEntry({
    required this.documentId,
    required this.name,
    required this.isDirectory,
    this.mimeType,
    this.size,
    this.lastModifiedMs,
    required this.supportsThumbnail,
  });

  final String documentId;
  final String name;
  final bool isDirectory;
  final String? mimeType;
  final int? size;

  /// Milliseconds since the epoch, null when the provider does not tell
  final int? lastModifiedMs;

  /// Whether the provider makes a thumbnail of it (DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL)
  final bool supportsThumbnail;
}

@HostApi()
abstract class DocumentTreeApi {
  /// Opens the system folder picker; null when the user goes back. The read grant is persisted when the provider
  /// allows it, so that the folder can be opened again after a restart while it stays plugged in.
  @async
  TreePick? pickTree();

  /// The folder [treeUri] picked before, when it can still be read (still plugged in, grant kept); null otherwise
  @async
  TreePick? reopen(String treeUri);

  /// The files and folders of the folder [documentId] of [treeUri] (null for the folder picked): one query, asked
  /// again while the provider says it is still loading (an MTP device lists its files in batches)
  @async
  List<DocEntry> list(String treeUri, String? documentId);

  /// The file or folder [documentId] of [treeUri] (null for the folder picked)
  @async
  DocEntry stat(String treeUri, String? documentId);

  /// [length] bytes of the file [documentId] from [offset]; fewer at its end. Read at the position when the file
  /// allows it, else from its start (a device that cannot read parts of a file). Fails with the code "unplugged" when
  /// the device is gone.
  @async
  Uint8List read(String treeUri, String documentId, int offset, int length);

  /// The thumbnail the provider makes of [documentId], a JPEG about [size] pixels on its long side; null when it
  /// makes none
  @async
  Uint8List? thumbnail(String treeUri, String documentId, int size);

  /// Copies the file [documentId] into the gallery of the phone, album [album] under DCIM, named [name], as [mimeType],
  /// taken at [takenAtMs]; gives the content URI of the copy. Streams from the file to the gallery, no copy in the
  /// cache; [copyId] names it for [DocumentTreeEvents.onCopyProgress] and [cancelCopy]. Fails with the code
  /// "cancelled" once cancelled, and leaves no partial file.
  @async
  String copyToGallery(
    int copyId,
    String treeUri,
    String documentId,
    String name,
    String mimeType,
    String album,
    int takenAtMs,
  );

  /// Stops the copy [copyId]
  void cancelCopy(int copyId);

  /// Closes the files of [treeUri] kept open between reads
  void closeTree(String treeUri);

  /// Gives back the read grant of [treeUri]: the folder is forgotten
  void release(String treeUri);

  /// Tells [DocumentTreeEvents.onUsbChanged] when a USB device or volume comes or goes, while [watch] is true
  void watchUsb(bool watch);
}

@FlutterApi()
abstract class DocumentTreeEvents {
  /// [bytes] of [total] copied by the copy [copyId] (see [DocumentTreeApi.copyToGallery])
  void onCopyProgress(int copyId, int bytes, int total);

  /// A USB device or volume was plugged in ([attached]) or unplugged
  void onUsbChanged(bool attached);
}
