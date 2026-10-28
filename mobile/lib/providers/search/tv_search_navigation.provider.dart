import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Whether Search currently shows a query/filter rather than its starting suggestions.
/// The TV tab shell reads this to make Back return to the main Search screen.
final tvSearchHasActiveQueryProvider = StateProvider<bool>((ref) => false);

/// Incremented by the TV tab shell when Back should clear Search instead of
/// taking focus straight to the navigation rail. SearchPage owns its filter state.
final tvSearchReturnToStartProvider = StateProvider<int>((ref) => 0);
