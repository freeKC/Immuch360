import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/entry_names.dart';

void main() {
  group('safeEntryName', () {
    test('replaces what a path cannot hold', () {
      expect(safeEntryName('Night/Day'), 'Night_Day');
      expect(safeEntryName(r'a\b'), 'a_b');
      expect(safeEntryName('tab\there'), 'tab_here');
      expect(safeEntryName('  trimmed  '), 'trimmed');
    });

    test('never gives an empty name or one that points to another folder', () {
      expect(safeEntryName(''), '_');
      expect(safeEntryName('   '), '_');
      expect(safeEntryName('.'), '_');
      expect(safeEntryName('..'), '_');
      expect(safeEntryName('...'), '...');
    });
  });

  group('uniqueEntryNames', () {
    List<String> namesOf(List<(String, bool)> items) => [
      for (final named in uniqueEntryNames(items, (item) => item.$1, (item) => item.$2)) named.name,
    ];

    test('numbers a name taken before, without case, before the extension of a file', () {
      expect(namesOf([('a.jpg', false), ('A.jpg', false), ('a.jpg', false)]), ['a.jpg', 'A (2).jpg', 'a (3).jpg']);
    });

    test('numbers a folder at its end, its dot being no extension', () {
      expect(namesOf([('v1.2', true), ('V1.2', true)]), ['v1.2', 'V1.2 (2)']);
    });

    test('does not take a number another entry already has', () {
      expect(namesOf([('a (2).jpg', false), ('a.jpg', false), ('a.jpg', false)]), ['a (2).jpg', 'a.jpg', 'a (3).jpg']);
    });

    test('leaves out the items without a name, keeping the order of the others', () {
      final named = uniqueEntryNames(['x', 'skip', 'y'], (item) => item == 'skip' ? null : item, (_) => false);
      expect([for (final entry in named) entry.item], ['x', 'y']);
    });
  });
}
