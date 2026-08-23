import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'startup_log.dart';

const String kLiveSyncHost = 'sync.velvet-leaf.com';
const Duration _validatedAddressLifetime = Duration(minutes: 10);
const Duration _maximumDohLifetime = Duration(hours: 1);
const int _maximumDohResponseBytes = 64 * 1024;

class DnsFallbackEndpoint {
  const DnsFallbackEndpoint({
    required this.host,
    required this.bootstrapAddress,
    required this.queryPath,
  });

  final String host;
  final String bootstrapAddress;
  final String Function(String hostName) queryPath;
}

const List<DnsFallbackEndpoint> kDnsFallbackEndpoints = <DnsFallbackEndpoint>[
  DnsFallbackEndpoint(
    host: 'cloudflare-dns.com',
    bootstrapAddress: '1.1.1.1',
    queryPath: _cloudflareDnsQueryPath,
  ),
  DnsFallbackEndpoint(
    host: 'dns.google',
    bootstrapAddress: '8.8.8.8',
    queryPath: _googleDnsQueryPath,
  ),
];

String _cloudflareDnsQueryPath(String hostName) =>
    '/dns-query?name=${Uri.encodeQueryComponent(hostName)}&type=A';

String _googleDnsQueryPath(String hostName) =>
    '/resolve?name=${Uri.encodeQueryComponent(hostName)}&type=A';

typedef DnsJsonFetcher =
    Future<Map<String, dynamic>> Function(
      DnsFallbackEndpoint endpoint,
      String hostName,
    );

class ResilientDnsCacheEntry {
  const ResilientDnsCacheEntry({
    required this.addresses,
    required this.expiresAtUtc,
  });

  final List<String> addresses;
  final DateTime expiresAtUtc;

  bool isUsableAt(DateTime nowUtc) =>
      expiresAtUtc.isAfter(nowUtc) && addresses.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'addresses': addresses,
    'expiresAtUtc': expiresAtUtc.toIso8601String(),
  };

  static ResilientDnsCacheEntry? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final rawAddresses = value['addresses'];
    final rawExpiry = value['expiresAtUtc'];
    if (rawAddresses is! List || rawExpiry is! String) {
      return null;
    }
    final expiry = DateTime.tryParse(rawExpiry)?.toUtc();
    if (expiry == null) {
      return null;
    }
    final addresses = rawAddresses
        .whereType<String>()
        .where(isSafePublicIpv4Address)
        .toSet()
        .toList(growable: false);
    if (addresses.isEmpty) {
      return null;
    }
    return ResilientDnsCacheEntry(addresses: addresses, expiresAtUtc: expiry);
  }
}

bool isSafePublicIpv4Address(String value) {
  final address = InternetAddress.tryParse(value);
  if (address == null || address.type != InternetAddressType.IPv4) {
    return false;
  }
  final bytes = address.rawAddress;
  final first = bytes[0];
  final second = bytes[1];
  if (first == 0 || first == 10 || first == 127 || first >= 224) {
    return false;
  }
  if (first == 100 && second >= 64 && second <= 127) {
    return false;
  }
  if (first == 169 && second == 254) {
    return false;
  }
  if (first == 172 && second >= 16 && second <= 31) {
    return false;
  }
  if (first == 192 && second == 168) {
    return false;
  }
  return true;
}

List<String> parseDnsJsonIpv4Addresses(Map<String, dynamic> payload) {
  final status = payload['Status'];
  if (status is! num || status.toInt() != 0) {
    return const <String>[];
  }
  final answers = payload['Answer'];
  if (answers is! List) {
    return const <String>[];
  }
  return answers
      .whereType<Map>()
      .where((answer) => answer['type'] == 1 || answer['type'] == 1.0)
      .map((answer) => answer['data'])
      .whereType<String>()
      .where(isSafePublicIpv4Address)
      .toSet()
      .toList(growable: false);
}

Duration dnsJsonLifetime(Map<String, dynamic> payload) {
  final answers = payload['Answer'];
  if (answers is! List) {
    return const Duration(minutes: 5);
  }
  final ttls = answers
      .whereType<Map>()
      .where((answer) => answer['type'] == 1 || answer['type'] == 1.0)
      .map((answer) => answer['TTL'])
      .whereType<num>()
      .map((ttl) => ttl.toInt())
      .where((ttl) => ttl > 0)
      .toList(growable: false);
  if (ttls.isEmpty) {
    return const Duration(minutes: 5);
  }
  final seconds = ttls.reduce((left, right) => left < right ? left : right);
  final bounded = seconds.clamp(60, _maximumDohLifetime.inSeconds);
  return Duration(seconds: bounded);
}

class ResilientDnsResolver {
  ResilientDnsResolver({
    File? cacheFile,
    DateTime Function()? nowUtc,
    DnsJsonFetcher? fetcher,
    List<DnsFallbackEndpoint> endpoints = kDnsFallbackEndpoints,
  }) : _cacheFile = cacheFile ?? _defaultCacheFile(),
       _nowUtc = nowUtc ?? (() => DateTime.now().toUtc()),
       _fetcher = fetcher,
       _endpoints = endpoints;

  final File _cacheFile;
  final DateTime Function() _nowUtc;
  final DnsJsonFetcher? _fetcher;
  final List<DnsFallbackEndpoint> _endpoints;
  final Map<String, ResilientDnsCacheEntry> _memory =
      <String, ResilientDnsCacheEntry>{};
  Future<void>? _loadFuture;
  Future<void> _saveTail = Future<void>.value();

  static File _defaultCacheFile() {
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim() ?? '';
    final root =
        localAppData.isEmpty ? Directory.systemTemp.path : localAppData;
    return File(
      '$root${Platform.pathSeparator}VelvetLeafSqlSync'
      '${Platform.pathSeparator}dns-fallback-cache.json',
    );
  }

  Future<List<String>> cachedAddresses(String hostName) async {
    await _load();
    final normalized = hostName.trim().toLowerCase();
    final entry = _memory[normalized];
    if (entry == null || !entry.isUsableAt(_nowUtc())) {
      return const <String>[];
    }
    return entry.addresses;
  }

  Future<void> rememberValidatedAddress(
    String hostName,
    InternetAddress address,
  ) async {
    if (!isSafePublicIpv4Address(address.address)) {
      return;
    }
    await _load();
    final normalized = hostName.trim().toLowerCase();
    final current = _memory[normalized];
    final addresses = <String>{
      address.address,
      ...?current?.addresses,
    }.toList(growable: false);
    _memory[normalized] = ResilientDnsCacheEntry(
      addresses: addresses,
      expiresAtUtc: _nowUtc().add(_validatedAddressLifetime),
    );
    await _save();
  }

  Future<List<String>> resolve(String hostName) async {
    final normalized = hostName.trim().toLowerCase();
    final cached = await cachedAddresses(normalized);
    if (cached.isNotEmpty) {
      return cached;
    }
    Object? lastError;
    final resolvedAddresses = <String>{};
    Duration? resolvedLifetime;
    for (final endpoint in _endpoints) {
      try {
        final payload = await (_fetcher ?? _fetchDnsJson)(endpoint, normalized);
        final addresses = parseDnsJsonIpv4Addresses(payload);
        if (addresses.isNotEmpty) {
          resolvedAddresses.addAll(addresses);
          final lifetime = dnsJsonLifetime(payload);
          if (resolvedLifetime == null || lifetime < resolvedLifetime) {
            resolvedLifetime = lifetime;
          }
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (resolvedAddresses.isNotEmpty) {
      final addresses = resolvedAddresses.toList(growable: false);
      _memory[normalized] = ResilientDnsCacheEntry(
        addresses: addresses,
        expiresAtUtc: _nowUtc().add(
          resolvedLifetime ?? const Duration(minutes: 5),
        ),
      );
      await _save();
      return addresses;
    }
    throw SocketException(
      'Secure DNS fallback could not resolve $normalized${lastError == null ? '' : ': $lastError'}',
    );
  }

  Future<Map<String, dynamic>> _fetchDnsJson(
    DnsFallbackEndpoint endpoint,
    String hostName,
  ) async {
    final client =
        HttpClient()
          ..connectionTimeout = const Duration(seconds: 15)
          ..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final socket = _connectTlsToAddress(
        endpoint.bootstrapAddress,
        endpoint.host,
        uri.hasPort ? uri.port : 443,
      );
      return Future.value(ConnectionTask.fromSocket<Socket>(socket, () {}));
    };
    try {
      final uri = Uri.https(endpoint.host, endpoint.queryPath(hostName));
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'DNS-over-HTTPS returned HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maximumDohResponseBytes) {
          throw const FormatException('DNS-over-HTTPS response is too large.');
        }
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected DNS-over-HTTPS response.');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _load() async {
    return _loadFuture ??= _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    try {
      if (!await _cacheFile.exists()) {
        return;
      }
      final decoded = jsonDecode(await _cacheFile.readAsString());
      if (decoded is! Map) {
        return;
      }
      for (final entry in decoded.entries) {
        if (entry.key is! String) {
          continue;
        }
        final parsed = ResilientDnsCacheEntry.fromJson(entry.value);
        if (parsed != null && parsed.isUsableAt(_nowUtc())) {
          _memory[(entry.key as String).toLowerCase()] = parsed;
        }
      }
    } catch (error) {
      logStartupEvent('Ignoring invalid DNS fallback cache: $error');
    }
  }

  Future<void> _save() async {
    final encoded = jsonEncode(
      _memory.map(
        (host, entry) => MapEntry<String, dynamic>(host, entry.toJson()),
      ),
    );
    _saveTail = _saveTail.then((_) => _writeCache(encoded)).catchError((
      Object error,
    ) {
      logStartupEvent('Could not persist DNS fallback cache: $error');
    });
    await _saveTail;
  }

  Future<void> _writeCache(String encoded) async {
    try {
      await _cacheFile.parent.create(recursive: true);
      final temporary = File(
        '${_cacheFile.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await temporary.writeAsString(encoded, flush: true);
      if (await _cacheFile.exists()) {
        await _cacheFile.delete();
      }
      await temporary.rename(_cacheFile.path);
    } catch (error) {
      logStartupEvent('Could not persist DNS fallback cache: $error');
    }
  }
}

final ResilientDnsResolver _sharedDnsResolver = ResilientDnsResolver();

http.Client createResilientHttpClient({
  String fallbackHost = kLiveSyncHost,
  ResilientDnsResolver? resolver,
}) => IOClient(
  createResilientDartHttpClient(fallbackHost: fallbackHost, resolver: resolver),
);

HttpClient createResilientDartHttpClient({
  String fallbackHost = kLiveSyncHost,
  ResilientDnsResolver? resolver,
}) {
  final resolvedFallbackHost = fallbackHost.trim().toLowerCase();
  final dnsResolver = resolver ?? _sharedDnsResolver;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  client.connectionFactory = (uri, proxyHost, proxyPort) {
    Socket? activeSocket;
    var cancelled = false;
    final socketFuture = _connectResiliently(
      uri: uri,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      fallbackHost: resolvedFallbackHost,
      resolver: dnsResolver,
      onSocket: (socket) {
        activeSocket = socket;
        if (cancelled) {
          socket.destroy();
        }
      },
    );
    return Future.value(
      ConnectionTask.fromSocket<Socket>(socketFuture, () {
        cancelled = true;
        activeSocket?.destroy();
      }),
    );
  };
  return client;
}

Future<Socket> _connectResiliently({
  required Uri uri,
  required String? proxyHost,
  required int? proxyPort,
  required String fallbackHost,
  required ResilientDnsResolver resolver,
  required void Function(Socket socket) onSocket,
}) async {
  if (proxyHost != null && proxyHost.isNotEmpty) {
    final socket = await Socket.connect(proxyHost, proxyPort ?? 8080);
    onSocket(socket);
    return socket;
  }
  final hostName = uri.host.toLowerCase();
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  if (uri.scheme != 'https' || hostName != fallbackHost) {
    final socket = await Socket.connect(uri.host, port);
    onSocket(socket);
    return socket;
  }

  Object? systemError;
  try {
    final socket = await _connectTlsToAddress(uri.host, uri.host, port);
    onSocket(socket);
    await resolver.rememberValidatedAddress(hostName, socket.remoteAddress);
    return socket;
  } catch (error) {
    systemError = error;
  }

  final addresses = await resolver.resolve(hostName);
  Object? fallbackError;
  for (final address in addresses) {
    try {
      final socket = await _connectTlsToAddress(address, uri.host, port);
      onSocket(socket);
      await resolver.rememberValidatedAddress(hostName, socket.remoteAddress);
      logStartupEvent(
        'Connected to $hostName through verified DNS fallback address $address.',
      );
      return socket;
    } catch (error) {
      fallbackError = error;
    }
  }
  throw SocketException(
    'Could not securely connect to $hostName through system DNS or verified fallback addresses. '
    'System error: $systemError. Fallback error: $fallbackError',
  );
}

Future<SecureSocket> _connectTlsToAddress(
  Object address,
  String tlsHost,
  int port,
) async {
  final socket = await Socket.connect(
    address,
    port,
    timeout: const Duration(seconds: 30),
  );
  try {
    return await SecureSocket.secure(
      socket,
      host: tlsHost,
      supportedProtocols: const <String>['http/1.1'],
    ).timeout(const Duration(seconds: 30));
  } catch (_) {
    socket.destroy();
    rethrow;
  }
}
