// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'photo_cache.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Provider family keyed by album id. Each album gets its own
/// `Map<assetId, ResolvedPhoto>`; moving to another album leaves this
/// one untouched, and Riverpod can reclaim it once nothing watches.

@ProviderFor(PhotoCache)
final photoCacheProvider = PhotoCacheFamily._();

/// Provider family keyed by album id. Each album gets its own
/// `Map<assetId, ResolvedPhoto>`; moving to another album leaves this
/// one untouched, and Riverpod can reclaim it once nothing watches.
final class PhotoCacheProvider
    extends $NotifierProvider<PhotoCache, Map<String, ResolvedPhoto>> {
  /// Provider family keyed by album id. Each album gets its own
  /// `Map<assetId, ResolvedPhoto>`; moving to another album leaves this
  /// one untouched, and Riverpod can reclaim it once nothing watches.
  PhotoCacheProvider._(
      {required PhotoCacheFamily super.from, required String super.argument})
      : super(
          retry: null,
          name: r'photoCacheProvider',
          isAutoDispose: true,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$photoCacheHash();

  @override
  String toString() {
    return r'photoCacheProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  PhotoCache create() => PhotoCache();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(Map<String, ResolvedPhoto> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<Map<String, ResolvedPhoto>>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PhotoCacheProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$photoCacheHash() => r'dbcbc85db30f13565ae79af0c96914ef9e965813';

/// Provider family keyed by album id. Each album gets its own
/// `Map<assetId, ResolvedPhoto>`; moving to another album leaves this
/// one untouched, and Riverpod can reclaim it once nothing watches.

final class PhotoCacheFamily extends $Family
    with
        $ClassFamilyOverride<PhotoCache, Map<String, ResolvedPhoto>,
            Map<String, ResolvedPhoto>, Map<String, ResolvedPhoto>, String> {
  PhotoCacheFamily._()
      : super(
          retry: null,
          name: r'photoCacheProvider',
          dependencies: null,
          $allTransitiveDependencies: null,
          isAutoDispose: true,
        );

  /// Provider family keyed by album id. Each album gets its own
  /// `Map<assetId, ResolvedPhoto>`; moving to another album leaves this
  /// one untouched, and Riverpod can reclaim it once nothing watches.

  PhotoCacheProvider call(
    String albumId,
  ) =>
      PhotoCacheProvider._(argument: albumId, from: this);

  @override
  String toString() => r'photoCacheProvider';
}

/// Provider family keyed by album id. Each album gets its own
/// `Map<assetId, ResolvedPhoto>`; moving to another album leaves this
/// one untouched, and Riverpod can reclaim it once nothing watches.

abstract class _$PhotoCache extends $Notifier<Map<String, ResolvedPhoto>> {
  late final _$args = ref.$arg as String;
  String get albumId => _$args;

  Map<String, ResolvedPhoto> build(
    String albumId,
  );
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref
        as $Ref<Map<String, ResolvedPhoto>, Map<String, ResolvedPhoto>>;
    final element = ref.element as $ClassProviderElement<
        AnyNotifier<Map<String, ResolvedPhoto>, Map<String, ResolvedPhoto>>,
        Map<String, ResolvedPhoto>,
        Object?,
        Object?>;
    element.handleCreate(
        ref,
        () => build(
              _$args,
            ));
  }
}
