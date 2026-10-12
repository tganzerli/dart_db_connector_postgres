/// PostgreSQL built-in type OIDs.
///
/// Stable across Postgres versions for built-in types (sourced from
/// `src/include/catalog/pg_type.dat`). Custom types from extensions may
/// have OIDs that fall outside this list — those decode as `unknown`
/// (raw `Uint8List`) by [postgresTypeFromOid].
///
/// Reference: PostgreSQL frontend/backend protocol, version 3
/// (data types section).
library;

/// Catalog of stable built-in PostgreSQL type OIDs.
///
/// Each constant is the raw OID value taken from `pg_type.dat`. These
/// values are stable across Postgres versions for built-in types, so
/// consumers can compare directly against [PostgresResultSet.columnOids] to
/// detect column types — useful for handling extension or custom
/// types that fall outside [PostgresType].
///
/// Example:
/// ```dart
/// final isNumeric = rs.columnOids[idx] == PostgresOid.numeric;
/// ```
abstract final class PostgresOid {
  /// `bool` (size 1 in binary; 't'/'f' in text)
  static const int boolean = 16;

  /// `bytea` (binary data; text uses `\x<hex>` prefix)
  static const int bytea = 17;

  /// `"char"` (single byte; catalog category codes such as
  /// `pg_class.relkind`). Not `char(N)`, which is [bpchar].
  static const int char = 18;

  /// `name` (catalog identifier, up to 63 bytes, e.g. `pg_class.relname`)
  static const int name = 19;

  /// `int8` / `bigint`
  static const int int8 = 20;

  /// `int2` / `smallint`
  static const int int2 = 21;

  /// `int4` / `integer`
  static const int int4 = 23;

  /// `text` (variable-length, UTF-8)
  static const int text = 25;

  /// `numeric` / `decimal` (arbitrary precision; in text mode comes as
  /// a decimal string like `"123.45"`). Decoded as `double` here for
  /// ergonomics — TPC-C-style money math is < 8 decimal digits and
  /// fits in IEEE 754 without loss. If exact decimal is needed, the
  /// caller can read the raw bytes and use a BigDecimal package.
  static const int numeric = 1700;

  /// `json`
  static const int json = 114;

  /// `float4` / `real`
  static const int float4 = 700;

  /// `float8` / `double precision`
  static const int float8 = 701;

  /// `bpchar` (blank-padded `char(N)`)
  static const int bpchar = 1042;

  /// `varchar`
  static const int varchar = 1043;

  /// `timestamp` (without time zone)
  static const int timestamp = 1114;

  /// `timestamptz` (with time zone)
  static const int timestamptz = 1184;

  /// `jsonb`
  static const int jsonb = 3802;

  /// `date` (binary: `int32` big-endian of days since 2000-01-01, signed —
  /// dates before 2000 arrive negative). No time, no time zone.
  ///
  /// Source: `date_send` + `POSTGRES_EPOCH_JDATE`.
  static const int date = 1082;

  /// `uuid` (binary: 16 raw bytes, RFC 4122 order — no field-wise byte
  /// swapping, unlike Microsoft GUID; text: canonical 8-4-4-4-12 hex).
  ///
  /// Source: `uuid_send` + `UUID_LEN`.
  static const int uuid = 2950;
}
