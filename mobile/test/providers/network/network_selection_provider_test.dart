import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/network/network_selection.provider.dart';

void main() {
  const folder = (sourceId: 'nas', path: '/photos');
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  /// The selection of [key], kept alive for the test: the provider forgets it once nobody listens
  NetworkSelection selectionOf([NetworkFolderKey key = folder]) {
    container.listen(networkSelectionProvider(key), (_, _) {});
    return container.read(networkSelectionProvider(key));
  }

  NetworkSelectionNotifier notifierOf([NetworkFolderKey key = folder]) {
    container.listen(networkSelectionProvider(key), (_, _) {});
    return container.read(networkSelectionProvider(key).notifier);
  }

  test('is not picking anything at first', () {
    final selection = selectionOf();

    expect(selection.isActive, isFalse);
    expect(selection.paths, isEmpty);
  });

  test('starts picking with nothing picked, or with the file long pressed', () {
    final notifier = notifierOf();

    notifier.start();
    expect(selectionOf().isActive, isTrue);
    expect(selectionOf().paths, isEmpty);

    notifier.start('/photos/a.jpg');
    expect(selectionOf().paths, {'/photos/a.jpg'});
  });

  test('a toggle picks a file, and a second one leaves it out', () {
    final notifier = notifierOf()..start('/photos/a.jpg');

    notifier.toggle('/photos/b.jpg');
    expect(selectionOf().paths, {'/photos/a.jpg', '/photos/b.jpg'});
    expect(selectionOf().contains('/photos/b.jpg'), isTrue);

    notifier.toggle('/photos/a.jpg');
    expect(selectionOf().paths, {'/photos/b.jpg'});
    expect(selectionOf().contains('/photos/a.jpg'), isFalse);
    expect(selectionOf().isActive, isTrue, reason: 'still picking');
  });

  test('picking every file picks them all, then none once they all were', () {
    final notifier = notifierOf()..start('/photos/a.jpg');
    const all = ['/photos/a.jpg', '/photos/b.jpg', '/photos/c.mp4'];

    notifier.toggleAll(all);
    expect(selectionOf().paths, all.toSet());

    notifier.toggleAll(all);
    expect(selectionOf().paths, isEmpty);
    expect(selectionOf().isActive, isTrue);
  });

  test('stops picking, forgetting the files picked', () {
    final notifier = notifierOf()..start('/photos/a.jpg');

    notifier.end();

    expect(selectionOf().isActive, isFalse);
    expect(selectionOf().paths, isEmpty);
  });

  test('keeps the selection of each folder apart', () {
    const other = (sourceId: 'nas', path: '/videos');
    const otherShare = (sourceId: 'other', path: '/photos');

    notifierOf().start('/photos/a.jpg');

    expect(selectionOf(other).isActive, isFalse);
    expect(selectionOf(otherShare).isActive, isFalse);
    expect(selectionOf().paths, {'/photos/a.jpg'});
  });

  test('forgets the selection once the browser of the folder is gone', () async {
    final subscription = container.listen(networkSelectionProvider(folder), (_, _) {});
    container.read(networkSelectionProvider(folder).notifier).start('/photos/a.jpg');

    subscription.close();
    await container.pump();

    expect(container.read(networkSelectionProvider(folder)).isActive, isFalse);
  });
}
