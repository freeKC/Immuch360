// The folder and file dialogs of the operating system, for the places where a computer keeps files: the download
// folder, "Save to a folder" and "Save logs to a file".
//
// They go through file_selector's platform interface, whose Windows, Linux and macOS implementations already come
// with image_picker: depending on file_selector itself would add its Android and iOS implementations to the phone
// builds (Design 8.3). The interface package is a dependency of image_picker only, hence the ignore below; listing
// it in pubspec.yaml would remove the need for it without changing any plugin list.

// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';

/// The two dialogs the desktop files need, behind an interface so that tests answer them
abstract interface class FilePickers {
  /// A folder the user picks, null when the dialog was closed
  Future<String?> folder({String? initialDirectory, String? confirmButtonText});

  /// Where to write a new file, starting from [suggestedName]; null when the dialog was closed
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  });
}

/// The dialogs of Windows, Linux and macOS
class SystemFilePickers implements FilePickers {
  const SystemFilePickers();

  @override
  Future<String?> folder({String? initialDirectory, String? confirmButtonText}) =>
      FileSelectorPlatform.instance.getDirectoryPathWithOptions(
        FileDialogOptions(initialDirectory: initialDirectory, confirmButtonText: confirmButtonText),
      );

  @override
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  }) async {
    final location = await FileSelectorPlatform.instance.getSaveLocation(
      acceptedTypeGroups: extensions.isEmpty ? null : [XTypeGroup(label: typeLabel, extensions: extensions)],
      options: SaveDialogOptions(initialDirectory: initialDirectory, suggestedName: suggestedName),
    );
    return location?.path;
  }
}

/// The dialogs the desktop files use; tests put theirs here
FilePickers get filePickers => _filePickers;
FilePickers _filePickers = const SystemFilePickers();

@visibleForTesting
set filePickers(FilePickers pickers) => _filePickers = pickers;
