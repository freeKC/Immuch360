// ignore_for_file: avoid_slow_async_io, avoid_print

import 'dart:convert';
import 'dart:io';

const _kReservedWords = [
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'Function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
];

const _kIntParamNames = [
  'count',
  'number',
  'amount',
  'total',
  'index',
  'size',
  'length',
  'width',
  'height',
  'year',
  'month',
  'day',
  'hour',
  'minute',
  'second',
  'page',
  'limit',
  'offset',
  'max',
  'min',
  'id',
  'num',
  'quantity',
];

const _kParamTypeOverrides = <String, String>{
  'advanced_settings_clear_image_cache_success.size': 'String',
  // Sizes of the AI components and of the relief cache, which the callers write with formatBytes ("94.5 MiB"); the
  // groups of features of the tile too ("3D scenes: 332.7 MiB")
  'ai_immersive_components_panoramas.size': 'String',
  'ai_immersive_components_photos.size': 'String',
  'ai_immersive_components_scenes.size': 'String',
  'ai_immersive_components_total.size': 'String',
  'ai_immersive_install_prompt.size': 'String',
  'ai_immersive_relief_cache_size.size': 'String',
  // The room to move of a 3D scene and the most triangles a headset takes: the headset of the viewer writes them in
  // ("18 cm", "400000"), so the labels it gets keep {size} and {max}, and the button of the 2D panel gives the digits
  'ai_immersive_scene_too_heavy.max': 'String',
  'ai_immersive_scene_zone.size': 'String',
  'ai_immersive_size_on_disk.size': 'String',
  // A length in millimetres, which the caller writes with its decimals for the locale
  'apple_spatial_baseline.mm': 'String',
  // The size of each eye of a spatial photo: the digits alone, as for the frame sizes below
  'apple_spatial_details_photo.height': 'String',
  'apple_spatial_details_photo.width': 'String',
  // An angle in degrees, written with its decimals by the caller as the baseline above
  'apple_spatial_fov.deg': 'String',
  'backup_controller_page_storage_format.total': 'String',
  'backup_controller_page_storage_format.used': 'String',
  // A size written out with its unit by the caller ("1.2 GB"), not a count
  'camera_cache_size.size': 'String',
  // An address written out by the caller, as the names and addresses below
  'camera_error_certificate_changed.host': 'String',
  'camera_error_unreachable.host': 'String',
  // Sizes written out with their unit by the caller, as the storage of the backup page
  'camera_sd_used.total': 'String',
  'camera_sd_used.used': 'String',
  'cleanup_found_assets_with_size.size': 'String',
  'in_year.year': 'String',
  // Progress of the copies into the gallery, counts of files
  'dji_import_keeping.done': 'int',
  'dji_import_keeping.total': 'int',
  // Names and addresses written out by the caller (a Bonjour name, "http://192.168.1.20:8360"), so that an
  // InternetAddress or a Uri, whose text is not the one shown, cannot be passed instead
  'network_share_relocating.name': 'String',
  'phone_share_headset_steps.name': 'String',
  'phone_share_notification_text.address': 'String',
  'phone_share_notification_text.user': 'String',
  'phone_share_subtitle_on.address': 'String',
  // The address outside home a Plex server told, and its port, which an int would write with a grouping separator
  // ("32,400")
  'plex_remote_learned.address': 'String',
  'plex_remote_learned.port': 'String',
  // The first digits of the machine id of a Plex server (hexadecimal), not a number
  'plex_server_found.id': 'String',
  // A date written out by the caller for the locale
  'plex_token_expires.date': 'String',
  // Counts of gaussians of a splat file, written out by the caller with the grouping of the language ("452,451"), or
  // left as {count} and {total} for the immersive viewer of the headset, which fills them in (lot S5)
  'splat_count.count': 'String',
  'splat_ply_line.count': 'String',
  'splat_ply_tool_line.count': 'String',
  'splat_reduced.total': 'String',
  'splat_spz_line.count': 'String',
  'splat_too_large.count': 'String',
  'splat_will_reduce.count': 'String',
  // Sizes written out with their unit by the caller ("3.4 GB"), and the extension of a file name ("osv")
  'upload_mobile_data_warning.size': 'String',
  'upload_refused_reason.kind': 'String',
  'upload_sheet_size.size': 'String',
  // The codec and the frame size of a lens, filled in by the native players: the digits alone, as for the frame sizes
  // below
  'raw_video_one_lens_decoder.codec': 'String',
  'raw_video_one_lens_decoder.height': 'String',
  'raw_video_one_lens_decoder.width': 'String',
  // A frame size such as "3840x3840", not a count
  'raw_video_two_decoders_heavy.size': 'String',
  // Frame sizes, which an int would write with grouping separators ("8,192 x 4,320"): the callers and the native
  // players give the digits alone
  'video_decoders_max.height': 'String',
  'video_decoders_max.width': 'String',
  'video_error_decoder.height': 'String',
  'video_error_decoder.width': 'String',
  'video_error_no_frame.height': 'String',
  'video_error_no_frame.width': 'String',
  'video_failed_beyond_decoders.height': 'String',
  'video_failed_beyond_decoders.maxHeight': 'String',
  'video_failed_beyond_decoders.maxWidth': 'String',
  'video_failed_beyond_decoders.width': 'String',
  'video_source_original_forced.height': 'String',
  'video_source_original_forced.width': 'String',
  'video_source_switched.height': 'String',
  'video_source_switched.width': 'String',
  'video_source_undecodable.height': 'String',
  'video_source_undecodable.width': 'String',
};

final _usedParamTypeOverrides = <String>{};

void main() async {
  final sourceFile = File('../i18n/en.json');
  if (!await sourceFile.exists()) {
    stderr.writeln('Source file does not exist');
    return;
  }

  final outputDir = Directory('lib/generated');
  await outputDir.create(recursive: true);

  final content = await sourceFile.readAsString();
  final translations = json.decode(content) as Map<String, dynamic>;

  final outputFile = File('lib/generated/translations.g.dart');
  await _generateTranslations(translations, outputFile);
  print('Generated ${outputFile.path}');
}

class TranslationNode {
  final String key;
  final String? value;
  final Map<String, TranslationNode> children;
  final List<TranslationParam> params;

  const TranslationNode({
    required this.key,
    this.value,
    Map<String, TranslationNode>? children,
    List<TranslationParam>? params,
  }) : children = children ?? const {},
       params = params ?? const [];

  bool get isLeaf => value != null;
  bool get hasParams => params.isNotEmpty;
}

class TranslationParam {
  final String name;
  final String type;

  const TranslationParam(this.name, this.type);
}

Future<void> _generateTranslations(Map<String, dynamic> translations, File output) async {
  final root = _buildTranslationTree('', translations);

  final staleOverrides = _kParamTypeOverrides.keys.toSet().difference(_usedParamTypeOverrides);
  if (staleOverrides.isNotEmpty) {
    throw StateError('_kParamTypeOverrides has entries matching no plain {placeholder}: ${staleOverrides.join(', ')}');
  }

  final buffer = StringBuffer('''
// DO NOT EDIT. This is code generated via generate_keys.dart

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/message_format.dart';

extension TranslationsExtension on BuildContext {
  Translations get t => Translations.of(this);
}

class StaticTranslations {
  StaticTranslations._();
  static final instance = Translations._(null);
}

abstract class _BaseTranslations {
  BuildContext? get _context;

  String _t(String key, [Map<String, Object>? args]) {
    if (key.isEmpty) return '';
    try {
      final translated = key.tr(context: _context);
      if (args == null) return translated;
      // The default locale is the language tag of the app locale, and intl has no number data for some of them (kab,
      // mi, swg...): MessageFormat would throw on those and the key would show instead of the sentence
      final locale = Intl.verifiedLocale(Intl.defaultLocale, NumberFormat.localeExists, onFailure: (_) => 'en')!;
      return MessageFormat(translated, locale: locale).format(args);
    } catch (e) {
      return key;
    }
  }
}

class Translations extends _BaseTranslations {
  @override
  final BuildContext? _context;
  Translations._(this._context);

  static Translations of(BuildContext context) {
    context.locale;
    return Translations._(context);
  }

''');

  _generateClassMembers(buffer, root, '  ');
  buffer.writeln('}');
  _generateNestedClasses(buffer, root);

  await output.writeAsString(buffer.toString());
}

TranslationNode _buildTranslationTree(String key, dynamic value, [String parentKey = '']) {
  final fullKey = parentKey.isEmpty ? key : '$parentKey.$key';
  if (value is Map<String, dynamic>) {
    final children = <String, TranslationNode>{};
    for (final entry in value.entries) {
      children[entry.key] = _buildTranslationTree(entry.key, entry.value, fullKey);
    }
    return TranslationNode(key: key, children: children);
  } else {
    final stringValue = value.toString();
    final params = _extractParams(stringValue, fullKey);
    return TranslationNode(key: key, value: stringValue, params: params);
  }
}

List<TranslationParam> _extractParams(String value, String fullKey) {
  final params = <String, TranslationParam>{};

  final icuRegex = RegExp(r'\{(\w+),\s*(plural|select|number|date|time)([^}]*(?:\{[^}]*\}[^}]*)*)\}');
  for (final match in icuRegex.allMatches(value)) {
    final name = match.group(1)!;
    final icuType = match.group(2)!;
    final icuContent = match.group(3) ?? '';

    if (params.containsKey(name)) {
      continue;
    }

    String type;
    if (icuType == 'plural' || icuType == 'number') {
      type = 'int';
    } else if (icuType == 'select') {
      final hasTrueFalse = RegExp(r',\s*(true|false)\s*\{').hasMatch(icuContent);
      type = hasTrueFalse ? 'bool' : 'String';
    } else {
      type = 'String';
    }

    params[name] = TranslationParam(name, type);
  }

  var cleanedValue = value;
  var depth = 0;
  var icuStart = -1;

  for (var i = 0; i < value.length; i++) {
    if (value[i] == '{') {
      if (depth == 0) {
        icuStart = i;
      }
      depth++;
    } else if (value[i] == '}') {
      depth--;
      if (depth == 0 && icuStart >= 0) {
        final block = value.substring(icuStart, i + 1);
        if (RegExp(r'^\{\w+,').hasMatch(block)) {
          cleanedValue = cleanedValue.replaceFirst(block, '');
        }
        icuStart = -1;
      }
    }
  }

  final simpleRegex = RegExp(r'\{(\w+)\}');
  for (final match in simpleRegex.allMatches(cleanedValue)) {
    final name = match.group(1)!;

    if (params.containsKey(name)) {
      continue;
    }

    final String type;
    if (_kParamTypeOverrides['$fullKey.$name'] case final override?) {
      type = override;
      _usedParamTypeOverrides.add('$fullKey.$name');
    } else if (_kIntParamNames.contains(name.toLowerCase())) {
      type = 'int';
    } else {
      type = 'Object';
    }

    params[name] = TranslationParam(name, type);
  }

  return params.values.toList();
}

void _generateClassMembers(StringBuffer buffer, TranslationNode node, String indent, [String keyPrefix = '']) {
  final sortedKeys = node.children.keys.toList()..sort();

  for (final childKey in sortedKeys) {
    final child = node.children[childKey]!;
    final dartName = _escapeName(childKey);
    final fullKey = keyPrefix.isEmpty ? childKey : '$keyPrefix.$childKey';

    if (child.isLeaf) {
      if (child.hasParams) {
        _generateMethod(buffer, dartName, fullKey, child.params, indent);
      } else {
        _generateGetter(buffer, dartName, fullKey, indent);
      }
    } else {
      final className = _toNestedClassName(keyPrefix, childKey);
      buffer.writeln('${indent}late final $dartName = $className._(_context);');
    }
  }
}

void _generateGetter(StringBuffer buffer, String dartName, String translationKey, String indent) {
  buffer.writeln('${indent}String get $dartName => _t(\'$translationKey\');');
}

void _generateMethod(
  StringBuffer buffer,
  String dartName,
  String translationKey,
  List<TranslationParam> params,
  String indent,
) {
  final paramList = params.map((p) => 'required ${p.type} ${_escapeName(p.name)}').join(', ');
  final argsMap = params.map((p) => '\'${p.name}\': ${_escapeName(p.name)}').join(', ');
  buffer.writeln('${indent}String $dartName({$paramList}) => _t(\'$translationKey\', {$argsMap});');
}

void _generateNestedClasses(StringBuffer buffer, TranslationNode node, [String keyPrefix = '']) {
  final sortedKeys = node.children.keys.toList()..sort();

  for (final childKey in sortedKeys) {
    final child = node.children[childKey]!;
    final fullKey = keyPrefix.isEmpty ? childKey : '$keyPrefix.$childKey';

    if (!child.isLeaf && child.children.isNotEmpty) {
      final className = _toNestedClassName(keyPrefix, childKey);
      buffer.writeln();
      buffer.writeln('class $className extends _BaseTranslations {');
      buffer.writeln('  @override');
      buffer.writeln('  final BuildContext? _context;');
      buffer.writeln('  $className._(this._context);');
      _generateClassMembers(buffer, child, '  ', fullKey);
      buffer.writeln('}');
      _generateNestedClasses(buffer, child, fullKey);
    }
  }
}

String _toNestedClassName(String prefix, String key) {
  final parts = <String>[];
  if (prefix.isNotEmpty) {
    parts.addAll(prefix.split('.'));
  }
  parts.add(key);

  final result = StringBuffer('_');
  for (final part in parts) {
    final words = part.split('_');
    for (final word in words) {
      if (word.isNotEmpty) {
        result.write(word[0].toUpperCase());
        if (word.length > 1) {
          result.write(word.substring(1).toLowerCase());
        }
      }
    }
  }
  result.write('Translations');

  return result.toString();
}

String _escapeName(String name) {
  if (_kReservedWords.contains(name)) {
    return '$name\$';
  }
  if (RegExp(r'^[0-9]').hasMatch(name)) {
    return 'k$name';
  }
  return name;
}
