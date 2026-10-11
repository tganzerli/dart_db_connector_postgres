/// Codec plan — cached decode layout keyed by result **shape**.
///
/// The read path used to re-derive everything on every query: per column
/// a `getFieldName().toDartString()` (FFI + UTF-8 decode + `String`
/// alloc) + `getFieldType()` (FFI), plus a rebuilt name→index map — even
/// when the same result shape repeats millions of times. And per cell it
/// branched on the OID (a `switch`) before decoding.
///
/// A [DecodePlan] captures, once per shape: the column names, the
/// name→index map, and a vector of per-column [CellDecoder]s (the OID
/// `switch` resolved ahead of time). [PostgresPlanCache]
/// keys plans by a fingerprint of the column OIDs (ints only, no string
/// work) and **verifies** a candidate by comparing the raw
/// column-name bytes, so two shapes that share OIDs but differ in names
/// never alias.
///
/// **Correctness of keying (why bytes, not just the hash):** two distinct
/// queries can produce identical OIDs with different column names
/// (`SELECT a::int, b::int` vs `SELECT x::int, y::int`). The fingerprint
/// only narrows the search; the byte-exact name check decides the hit, so
/// a wrong plan is structurally impossible. Schema changes that alter a
/// column's type change its OID → the fingerprint changes on its own; a
/// rename fails the byte check → a fresh plan is built. No manual
/// invalidation is ever required.
///
/// **Lifetime:** a plan stores only Dart heap (names, closures, cached
/// name bytes). It never retains a `PGresult` pointer, so caching is
/// independent of `PostgresResultSet.release()` / the finalizer.
///
/// **Isolation:** the cache is per-isolate (`static final` in library
/// scope). Dart isolates do not share heap, so "per pool" and "per
/// isolate" coincide within an isolate, and no lock is needed.
///
/// The [CellDecoder] signature names no Postgres type, so the same plan
/// shape backs the MySQL mirror — this is the candidate for a
/// SQL-agnostic seam. Only the Postgres builder is
/// materialised here; MySQL stays a documented follow-up.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../bindings/postgres_binding.dart';
import 'postgres_decoder.dart';

/// Immutable decode layout for one result shape. Shared (by reference)
/// across every [PostgresResultSet] of the same shape.
final class DecodePlan {
  /// Column names, indexed by position. Unmodifiable.
  final List<String> columnNames;

  /// Column type OIDs (Postgres) / type codes (future MySQL), indexed by
  /// position. Unmodifiable.
  final List<int> columnTypes;

  /// name → column index. Unmodifiable.
  final Map<String, int> nameToIndex;

  /// Per-column decoder, resolved once. Length == column count.
  final List<CellDecoder> decoders;

  /// Raw UTF-8 bytes of each column name (no NUL), for hit verification.
  final List<Uint8List> _rawNames;

  DecodePlan._(
    this.columnNames,
    this.columnTypes,
    this.nameToIndex,
    this.decoders,
    this._rawNames,
  );

  /// Empty shape (no rows, no columns) — backs `PostgresResultSet.empty()`.
  static final DecodePlan empty = DecodePlan._(
    const [],
    const [],
    const {},
    const [],
    const [],
  );

  /// Builds a plan straight from a freshly returned `PGresult`, without
  /// consulting or mutating any cache. Used by the `usePlanCache: false`
  /// A/B path in the decode microbenchmark.
  static DecodePlan buildPostgres(
      PostgresBinding binding, ffi.Pointer<ffi.Void> result, int cols,
      {required bool binary}) {
    final names = List<String>.filled(cols, '', growable: false);
    final oids = List<int>.filled(cols, 0, growable: false);
    final rawNames =
        List<Uint8List>.filled(cols, Uint8List(0), growable: false);
    final decoders =
        List<CellDecoder>.filled(cols, _nullDecoder, growable: false);
    final nameToIndex = <String, int>{};
    for (var c = 0; c < cols; c++) {
      final namePtr = binding.getFieldName(result, c);
      final byteLen = namePtr.length; // strlen (Utf8Pointer extension)
      rawNames[c] =
          Uint8List.fromList(namePtr.cast<ffi.Uint8>().asTypedList(byteLen));
      names[c] = namePtr.toDartString(length: byteLen);
      final oid = binding.getFieldType(result, c);
      oids[c] = oid;
      decoders[c] = binary ? binaryDecoderForOid(oid) : textDecoderForOid(oid);
      nameToIndex[names[c]] = c;
    }
    return DecodePlan._(
      List.unmodifiable(names),
      List.unmodifiable(oids),
      Map.unmodifiable(nameToIndex),
      List.unmodifiable(decoders),
      rawNames,
    );
  }

  static Object? _nullDecoder(ffi.Pointer<ffi.Uint8> ptr, int len) => null;
}

/// Per-isolate cache of [DecodePlan]s keyed by OID fingerprint, with
/// byte-exact name verification and a bounded size.
///
/// Eviction is insertion-order (FIFO), not access-order (LRU): the hit
/// path is intentionally reorder-free so the cache never taxes the query
/// it is meant to accelerate, and in the target workloads the shape count
/// (tens) sits far below [_maxPlans], so evictions never fire and FIFO vs
/// LRU is indistinguishable. If a workload ever churned through hundreds
/// of one-shot shapes, FIFO would still keep memory bounded.
final class PostgresPlanCache {
  /// Cap on cached plans. TPC-C has ~tens of shapes; a single-row lookup has one.
  /// 256 leaves ample headroom at a negligible footprint (each plan is a
  /// handful of strings + closures).
  static const int _maxPlans = 256;

  /// fingerprint → candidate plans (a list to hold real hash collisions
  /// and same-OID / different-name shapes).
  final Map<int, List<DecodePlan>> _buckets = {};

  /// Insertion order for FIFO eviction: front is oldest.
  final List<({int hash, DecodePlan plan})> _order = [];

  /// Returns the cached plan for the shape of [result], building and
  /// inserting one on a miss. [cols] is the already-read column count.
  DecodePlan planFor(PostgresBinding binding, ffi.Pointer<ffi.Void> result,
      int cols, bool binary) {
    final h = _fingerprint(binding, result, cols, binary);
    final bucket = _buckets[h];
    if (bucket != null) {
      for (final plan in bucket) {
        if (_namesMatch(plan, binding, result, cols)) return plan; // hit
      }
    }
    final plan =
        DecodePlan.buildPostgres(binding, result, cols, binary: binary);
    (_buckets[h] ??= <DecodePlan>[]).add(plan);
    _order.add((hash: h, plan: plan));
    if (_order.length > _maxPlans) _evictOldest();
    return plan;
  }

  /// FNV-1a over `(binary, cols, oid₀…oid_{n-1})`. Only integer reads —
  /// no `String` work, no allocation.
  int _fingerprint(PostgresBinding binding, ffi.Pointer<ffi.Void> result,
      int cols, bool binary) {
    var h = 0x811c9dc5;
    h = _mix(h, binary ? 1 : 0);
    h = _mix(h, cols);
    for (var c = 0; c < cols; c++) {
      h = _mix(h, binding.getFieldType(result, c));
    }
    return h;
  }

  static int _mix(int h, int value) {
    h ^= value & 0xffffffff;
    // FNV prime 16777619, masked to 32 bits to stay a small int.
    h = (h * 0x01000193) & 0xffffffff;
    return h;
  }

  /// Byte-exact comparison of the live column names against a candidate
  /// plan's cached name bytes. No `toDartString`, no allocation.
  bool _namesMatch(DecodePlan plan, PostgresBinding binding,
      ffi.Pointer<ffi.Void> result, int cols) {
    if (plan.columnNames.length != cols) return false;
    for (var c = 0; c < cols; c++) {
      final raw = binding.getFieldName(result, c).cast<ffi.Uint8>();
      final cached = plan._rawNames[c];
      var i = 0;
      for (; i < cached.length; i++) {
        if (raw[i] != cached[i]) return false;
      }
      if (raw[i] != 0) return false; // live name longer than cached
    }
    return true;
  }

  void _evictOldest() {
    final e = _order.removeAt(0);
    final bucket = _buckets[e.hash];
    if (bucket != null) {
      bucket.remove(e.plan);
      if (bucket.isEmpty) _buckets.remove(e.hash);
    }
  }

  /// Test-only: number of plans currently held.
  int get size => _order.length;
}
