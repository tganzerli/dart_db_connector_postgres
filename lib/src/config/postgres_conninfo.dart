/// Typed builder for the libpq connection string that [PoolConfig.connInfo]
/// takes, with TLS as an explicit choice.
library;

/// libpq `sslmode`. Without one, libpq uses [prefer], which encrypts when
/// the server offers TLS but never checks the certificate, so it does not
/// stop interception. [verifyFull] checks the chain and the host name, and
/// is the mode for a database reached over a network you do not control.
enum SslMode {
  /// No TLS.
  disable('disable'),

  /// Plain first, TLS if the server insists. No certificate check.
  allow('allow'),

  /// TLS if the server offers it, plain otherwise. No certificate check.
  /// What libpq does when no `sslmode` is given.
  prefer('prefer'),

  /// TLS required. No certificate check.
  require('require'),

  /// TLS required; the server certificate must chain to [sslRootCert].
  verifyCa('verify-ca'),

  /// TLS required; chain checked and the host name must match the
  /// certificate.
  verifyFull('verify-full');

  const SslMode(this.libpq);

  /// The value libpq expects.
  final String libpq;
}

/// A libpq connection string built from typed fields. [sslMode] has no
/// default on purpose: whoever builds the connection chooses whether and
/// how to use TLS. Every value is quoted and escaped, so passwords and
/// paths with spaces or quotes are safe.
///
/// ```dart
/// final pool = PostgresConnectionPool(PoolConfig(
///   connInfo: PostgresConnInfo(
///     host: 'db.example.com', database: 'app', user: 'app',
///     password: secret, sslMode: SslMode.verifyFull,
///     sslRootCert: '/etc/ssl/db-ca.pem',
///     sslCert: '/etc/ssl/app.crt', sslKey: '/etc/ssl/app.key',
///   ).build(),
/// ));
/// ```
class PostgresConnInfo {
  final String host;
  final int port;
  final String database;
  final String user;
  final String? password;
  final SslMode sslMode;

  /// CA that must have signed the server certificate (verify-ca/full).
  final String? sslRootCert;

  /// Client certificate and key, for servers that require one
  /// (`clientcert=verify-full` in pg_hba.conf). The key file must not be
  /// readable by group or others, or libpq refuses it.
  final String? sslCert;
  final String? sslKey;

  /// Certificate revocation list.
  final String? sslCrl;

  /// Seconds libpq waits to connect; `null` is libpq's default (no limit).
  final int? connectTimeout;
  final String? applicationName;

  const PostgresConnInfo({
    required this.host,
    this.port = 5432,
    required this.database,
    required this.user,
    this.password,
    required this.sslMode,
    this.sslRootCert,
    this.sslCert,
    this.sslKey,
    this.sslCrl,
    this.connectTimeout,
    this.applicationName,
  });

  /// The connection string, in libpq `key='value'` form.
  String build() {
    final parts = <String>[
      _kv('host', host),
      _kv('port', '$port'),
      _kv('dbname', database),
      _kv('user', user),
      if (password != null) _kv('password', password!),
      _kv('sslmode', sslMode.libpq),
      if (sslRootCert != null) _kv('sslrootcert', sslRootCert!),
      if (sslCert != null) _kv('sslcert', sslCert!),
      if (sslKey != null) _kv('sslkey', sslKey!),
      if (sslCrl != null) _kv('sslcrl', sslCrl!),
      if (connectTimeout != null) _kv('connect_timeout', '$connectTimeout'),
      if (applicationName != null) _kv('application_name', applicationName!),
    ];
    return parts.join(' ');
  }

  @override
  String toString() => 'PostgresConnInfo($host:$port/$database, user $user, '
      'sslmode ${sslMode.libpq})';

  // libpq: a value in single quotes, with \ and ' escaped by a backslash.
  static String _kv(String key, String value) =>
      "$key='${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
}
