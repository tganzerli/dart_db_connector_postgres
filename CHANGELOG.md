# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/). The package follows semver; the native library
(`libnative_db`) carries its own ABI version, `MAJOR.MINOR`, checked at load time: a different MAJOR is fatal, an
older MINOR than the Dart side expects is a warning.

## 0.1.1

Consumed by `git` reference to the tag `v0.1.1`. Native ABI `2.6`, same native library as `0.1.0`.

### Fixed

- `name` (OID 19) and `"char"` (OID 18) columns now decode as `String` in both text and binary results,
  and `typeOf` reports `PostgresType.text` for them. They used to come back as raw bytes, which hit every
  catalog query (`pg_class.relname`, `pg_roles.rolname`, `pg_class.relkind`). A `"char"` byte with the high
  bit set reads as `\ooo` in both formats, as the server renders it in text mode since PostgreSQL 15. Code
  that worked around it with `::text` keeps working.
- `execute` with several statements in one string (no parameters, text results, so the simple query protocol)
  now throws `QueryFailedException` with the server message when any statement fails, not only the first.
  An error from the second statement on used to be dropped: inside a transaction it surfaced on the next query
  as "current transaction is aborted"; outside one, the whole string was rolled back and `execute` returned
  normally. On success the result of the first statement is still the one returned.

### Documentation

- README: "Local PostgreSQL with TLS", the points where a local `verify-full` setup usually goes wrong (SAN, server
  key ownership, `pg_hba.conf`, client certificates per role, client key mode, CI).
- `example/05_tls.dart` and `example/README.md` no longer point to a directory that is not part of this
  repository; the certificates directory is now a required argument.

## 0.1.0

First public release, consumed by `git` reference to the tag `v0.1.0`. Native ABI `2.6`.

### Included

- Native connection pool (`PostgresConnectionPool`, `PoolConfig`): one libpq connection per native thread,
  completions through Dart native ports, acquire timeout, optional instrumentation, graceful `close()` that
  waits for borrowed connections.
- Reconnection of a pooled connection whose link to the server was lost.
- Session reset when a connection returns to the pool (`sessionResetQuery`, default `DISCARD ALL`), with a
  rollback first for a connection returned inside a transaction; or deferred to the first statement of the next
  borrow (`deferSessionReset`, opt-in).
- Transactions: `withTransaction`, `withTransactionOn`, `withPipelinedTransaction`,
  `withTransactionInstrumented`; `withPostgresConnection` for autocommit work. The `BEGIN` of a transaction is
  deferred and sent together with its first statement.
- `PostgresUnitOfWork` and `PostgresRepository<T, K>` over the contracts of `dart_db_connector_core` 1.0.1.
- Extended Query protocol with typed parameters (`Param`), text and binary result decoding, `numeric` as
  `PostgresNumeric`, in-place reads through `PostgresResultSet` / `PostgresResultRow`.
- TLS through any libpq parameter, or `PostgresConnInfo` with an explicit `SslMode`; libpq's startup error
  message in `NativePoolStartupException`; credentials masked in every exception.
- Pre-built native library for `linux-x64`, `linux-arm64`, `macos-x64` and `macos-arm64` in `lib/_native/`.

### ABI history (MAJOR 2)

| MINOR | Adds |
|---|---|
| 0 | Native thread-per-connection pool: `pool_create`, `pool_acquire`, `pool_release`, `pool_submit_query`, `pool_submit_pipeline`, `pool_cancel`, `pool_destroy` |
| 1 | `pool_submit_query_params`: Extended Query protocol with bound parameters |
| 2 | Several reads in one round trip |
| 3 | Reconnection policy for a lost link |
| 4 | libpq's message for a failed `pool_create` |
| 5 | A statement prefix (the deferred `BEGIN`) in the same Extended pipeline |
| 6 | N statement prefixes under one Sync, and the transaction status without a round trip |
