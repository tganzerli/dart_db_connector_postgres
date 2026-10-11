import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';

/// Deferred pool session reset (2026-10-10).
///
/// With `PoolConfig.deferSessionReset`, a released connection is only
/// marked here; the reset rides the first statement of the next
/// acquisition, so it costs no round-trip of its own. The executor looks
/// the connection up on its first dispatch and, if marked, prefixes
/// [prefix] to it.
///
/// The registry is per isolate, like the pools that fill it, and keyed by
/// the native connection address. Pools unmark their connections on close.
@internal
abstract final class DeferredSessionReset {
  /// `DISCARD ALL`, decomposed: `DISCARD ALL` refuses to run inside a
  /// transaction block or next to another statement (SQLSTATE 25001), so
  /// it cannot be fused. These are the statements the PostgreSQL docs
  /// list as its equivalent; each one is a single statement, so the list
  /// also fits the Extended path as N pipeline prefixes.
  static const List<String> statements = [
    'SET SESSION AUTHORIZATION DEFAULT',
    'RESET ALL',
    'DEALLOCATE ALL',
    'CLOSE ALL',
    'UNLISTEN *',
    'SELECT pg_advisory_unlock_all()',
    'DISCARD PLANS',
    'DISCARD SEQUENCES',
    'DISCARD TEMP',
  ];

  /// [statements] inside an explicit `BEGIN … COMMIT`.
  ///
  /// Without the explicit block the reset shares the implicit
  /// transaction of the statement it is fused into, and a failure of that
  /// statement undoes part of it: `RESET ALL`, `SET SESSION
  /// AUTHORIZATION`, `UNLISTEN` and `DISCARD TEMP` roll back, while
  /// `DEALLOCATE ALL`, `CLOSE ALL`, the advisory unlock and `DISCARD
  /// SEQUENCES` do not. A bare `COMMIT` after the statements would also
  /// work but logs "there is no transaction in progress" on every
  /// acquisition. Verified on PostgreSQL 16.15.
  static List<String> get prefix =>
      debugFailingPrefix ? _failingPrefix : _prefix;

  static const List<String> _prefix = ['BEGIN', ...statements, 'COMMIT'];

  /// Same length as [_prefix], with a statement in the middle that always
  /// fails, so tests can drive the recovery path.
  static const List<String> _failingPrefix = [
    'BEGIN',
    ...['SET SESSION AUTHORIZATION DEFAULT', 'RESET ALL', 'DEALLOCATE ALL'],
    'SELECT 1/0',
    ...['UNLISTEN *', 'SELECT pg_advisory_unlock_all()', 'DISCARD PLANS'],
    ...['DISCARD SEQUENCES', 'DISCARD TEMP'],
    'COMMIT',
  ];

  /// Makes [prefix] fail mid-way. Tests only.
  @visibleForTesting
  static bool debugFailingPrefix = false;

  /// Standalone reset, for the paths that cannot carry a prefix
  /// (pipeline, an Extended statement with a library older than ABI
  /// MINOR 6) and to recover after a failed fused reset.
  static const String standalone = 'DISCARD ALL';

  static final Set<int> _pending = <int>{};

  /// Marks [conn] so its next first dispatch carries the reset.
  static void mark(ffi.Pointer<ffi.Void> conn) => _pending.add(conn.address);

  /// Removes the mark of [conn], returning whether it was marked.
  static bool take(ffi.Pointer<ffi.Void> conn) =>
      _pending.isNotEmpty && _pending.remove(conn.address);

  /// Whether [conn] is marked. Tests only.
  @visibleForTesting
  static bool isPending(ffi.Pointer<ffi.Void> conn) =>
      _pending.contains(conn.address);
}
