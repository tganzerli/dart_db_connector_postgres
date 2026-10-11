# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/). The package follows semver; the native library
(`libnative_db`) carries its own ABI version, `MAJOR.MINOR`, checked at load time: a different MAJOR is fatal, an
older MINOR than the Dart side expects is a warning.

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
