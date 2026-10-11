/// Ergonomic API for reading `PGresult` rows decoded as Dart values.
///
/// Built on top of [PostgresBinding]'s zero-copy ABI (MINOR 3) and type
/// introspection (MINOR 4). Decodes values in text-mode (the default
/// returned by `PQsendQuery`).
///
/// **Lifetime:** [PostgresResultSet] and any [PostgresResultRow]s derived from it are
/// valid only while the underlying `PGresult*` is alive. The current
/// PoC code releases via `binding.closeDb(conn)` (which clears all
/// pending results). A future `PQclear`-equivalent on the ABI will
/// give finer-grained control.
library;

import 'dart:ffi' as ffi;

import '../bindings/postgres_binding.dart';
import 'postgres_decode_plan.dart';
import 'postgres_numeric.dart';
import 'postgres_type.dart';

/// Internal handle passed to the Finalizer to free a `PGresult`.
class _PgResultHandle {
  final PostgresBinding binding;
  final ffi.Pointer<ffi.Void> result;
  const _PgResultHandle(this.binding, this.result);
}

/// Snapshot of a `PGresult` exposing decoded rows and column metadata.
///
/// Holds the row/column counts, column names, and Postgres OIDs of a
/// query result. Rows are decoded lazily via [row] / [rows]. Free the
/// underlying memory eagerly with [release] (idempotent); a finalizer
/// is attached as a safety net for forgotten releases.
///
/// Example:
/// ```dart
/// final rs = await exec.execute('SELECT id, name FROM users');
/// try {
///   for (final row in rs.rows) {
///     print('${row.getInt('id')} ${row.getString('name')}');
///   }
/// } finally {
///   rs.release();
/// }
/// ```
class PostgresResultSet {
  // Null only for `PostgresResultSet.empty()` — safe because row access is
  // guarded by rowCount and never reaches `_binding`/`_result` on an
  // empty result.
  final PostgresBinding? _binding;
  final ffi.Pointer<ffi.Void>? _result;

  /// Number of rows in the result.
  final int rowCount;

  /// Number of columns in the result.
  final int colCount;

  /// Cached decode layout for this result shape: column names,
  /// name→index map, and per-column decoders. Shared by reference across
  /// every [PostgresResultSet] of the same shape (see
  /// `postgres_decode_plan.dart`).
  final DecodePlan _plan;

  /// Wire format used for values: `false` = text (libpq default), `true`
  /// = binary (`PQsendQueryParams(..., resultFormat=1)`, ABI MINOR 1).
  /// Determines which decoder [PostgresResultRow] picks per column.
  final bool binary;

  /// Column names, indexed by column position. Unmodifiable.
  List<String> get columnNames => _plan.columnNames;

  /// Postgres type OIDs, indexed by column position. Unmodifiable.
  List<int> get columnOids => _plan.columnTypes;

  /// Per-isolate cache of decode plans, keyed by result shape.
  static final PostgresPlanCache _planCache = PostgresPlanCache();

  bool _released = false;

  // Safety-net finalizer for callers who forget `release()`. The GC
  // fires the callback some time after the [PostgresResultSet] becomes
  // unreachable. Hot paths call `release()` explicitly to keep RSS
  // bounded without depending on GC timing (retro N=12 P-PQclear).
  static final Finalizer<_PgResultHandle> _finalizer =
      Finalizer<_PgResultHandle>((h) => h.binding.clearResult(h.result));

  PostgresResultSet._(
    this._binding,
    this._result,
    this.rowCount,
    this.colCount,
    this._plan,
    this.binary,
  ) {
    final b = _binding;
    final r = _result;
    if (b != null && r != null) {
      _finalizer.attach(this, _PgResultHandle(b, r), detach: this);
    }
  }

  /// An empty result set with no rows and no columns. Useful when a
  /// SQL statement legitimately produces no result (libpq returned a
  /// null `PGresult*`) and the caller still expects a `PostgresResultSet`
  /// shape — e.g. `BEGIN`/`COMMIT`-style commands, or test fakes.
  factory PostgresResultSet.empty() =>
      PostgresResultSet._(null, null, 0, 0, DecodePlan.empty, false);

  /// Reads metadata (count, names, OIDs) from a freshly returned
  /// `PGresult*`. Cheap — no row data is touched.
  ///
  /// Pass `binary: true` when the request used
  /// `PQsendQueryParams(..., resultFormat=1)` so cell decoding picks the
  /// binary path. Defaults to `false` (text wire format) for backward
  /// compatibility with the existing `pool_submit_query` path.
  ///
  /// `usePlanCache` (default `true`) reuses a cached [DecodePlan] for the
  /// result shape — skipping the per-query name/OID re-derivation and the
  /// per-cell OID `switch`. Set to `false` to force a fresh plan; used by
  /// the decode microbenchmark's A/B and available if a caller ever needs
  /// to bypass the shared cache.
  factory PostgresResultSet.fromResult(
      PostgresBinding binding, ffi.Pointer<ffi.Void> result,
      {bool binary = false, bool usePlanCache = true}) {
    final cols = binding.getColCount(result);
    final plan = usePlanCache
        ? _planCache.planFor(binding, result, cols, binary)
        : DecodePlan.buildPostgres(binding, result, cols, binary: binary);
    return PostgresResultSet._(
      binding,
      result,
      binding.getRowCount(result),
      cols,
      plan,
      binary,
    );
  }

  /// Frees the underlying `PGresult` immediately and detaches the
  /// finalizer. Idempotent. After calling, accessing any [PostgresResultRow]
  /// from this set is undefined behaviour. If not called explicitly,
  /// the finalizer cleans up when the object is garbage-collected.
  void release() {
    if (_released) return;
    _released = true;
    final b = _binding;
    final r = _result;
    if (b != null && r != null) {
      b.clearResult(r);
      _finalizer.detach(this);
    }
  }

  /// Returns the [PostgresResultRow] at index [i].
  PostgresResultRow row(int i) {
    RangeError.checkValueInInterval(i, 0, rowCount - 1, 'i');
    return PostgresResultRow._(this, i);
  }

  /// Lazy iterable over rows in result order. Indexed generation avoids
  /// the `sync*` state-machine overhead on the read hot path.
  Iterable<PostgresResultRow> get rows =>
      Iterable.generate(rowCount, (i) => PostgresResultRow._(this, i));

  /// Returns the [PostgresType] tag for column [col] (by index or name).
  PostgresType typeOf(Object col) {
    final idx = _resolve(col);
    return postgresTypeFromOid(columnOids[idx]);
  }

  int _resolve(Object col) {
    if (col is int) {
      RangeError.checkValueInInterval(col, 0, colCount - 1, 'col');
      return col;
    }
    if (col is String) {
      final idx = _plan.nameToIndex[col];
      if (idx == null) {
        throw ArgumentError('Unknown column: "$col". Known: $columnNames');
      }
      return idx;
    }
    throw ArgumentError('col must be int or String, got ${col.runtimeType}');
  }
}

/// A single row of a [PostgresResultSet]. Decodes values lazily on access.
///
/// Access columns by integer index or by name via `row[col]`. Typed
/// helpers ([getInt], [getString], [getDateTime], etc.) cast the value
/// to a Dart type; SQL NULL surfaces as `null`. For exotic OIDs not
/// mapped in [PostgresType], `row[col]` returns a raw `Uint8List`
/// (zero-copy view over the libpq buffer).
class PostgresResultRow {
  final PostgresResultSet _set;
  final int _index;

  PostgresResultRow._(this._set, this._index);

  /// Row index within the parent [PostgresResultSet].
  int get index => _index;

  /// Decoded value for column [key] (by `int` index or `String` name).
  /// Returns `null` when the underlying cell is SQL NULL.
  Object? operator [](Object key) {
    final col = _set._resolve(key);
    final binding = _set._binding!;
    final result = _set._result!;
    final ptr = binding.getRawValue(result, _index, col);
    if (ptr == ffi.nullptr) return null;
    final length = binding.getRawLength(result, _index, col);
    return _set._plan.decoders[col](ptr, length);
  }

  // ── Typed helpers ──

  bool? getBool(Object key) => this[key] as bool?;
  int? getInt(Object key) => this[key] as int?;

  /// Cell as a `double`, converting when the column is `numeric`.
  ///
  /// Since 2026-09-10 a `numeric` column decodes to [PostgresNumeric],
  /// which is exact. This getter keeps working for the consumers written
  /// against the old `double` behaviour, at the cost the conversion
  /// always had — [PostgresNumeric.toDouble] is lossy beyond ~15
  /// significant decimal digits. Reach for [getNumeric] when that
  /// matters, in particular for money.
  double? getDouble(Object key) {
    final v = this[key];
    if (v is PostgresNumeric) return v.toDouble();
    return v as double?;
  }

  /// Cell as an exact [PostgresNumeric]. `null` on SQL NULL.
  ///
  /// Throws if the column is not `numeric` — use [getDouble] for
  /// `float4`/`float8`, which are floating point on the server too and
  /// have no exact decimal to preserve.
  PostgresNumeric? getNumeric(Object key) => this[key] as PostgresNumeric?;

  String? getString(Object key) => this[key] as String?;
  DateTime? getDateTime(Object key) => this[key] as DateTime?;
  Object? getJson(Object key) => this[key];

  /// Returns the bytes of the cell as a `Uint8List` (zero-copy view).
  /// Returns `null` on SQL NULL.
  Object? getBytes(Object key) => this[key];

  /// Materialises the row as a `Map<String, Object?>` (eager decode of
  /// all columns). Convenient for debugging or returning JSON-friendly
  /// payloads; less efficient than per-column access.
  Map<String, Object?> toMap() {
    return {
      for (var c = 0; c < _set.colCount; c++) _set.columnNames[c]: this[c]
    };
  }

  @override
  String toString() => toMap().toString();
}
