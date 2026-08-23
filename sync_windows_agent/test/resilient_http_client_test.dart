import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/resilient_http_client.dart';

void main() {
  test('DNS JSON accepts only public IPv4 answers', () {
    final addresses = parseDnsJsonIpv4Addresses(<String, dynamic>{
      'Status': 0,
      'Answer': <Map<String, dynamic>>[
        <String, dynamic>{'type': 1, 'TTL': 300, 'data': '75.119.136.143'},
        <String, dynamic>{'type': 1, 'TTL': 300, 'data': '127.0.0.1'},
        <String, dynamic>{'type': 1, 'TTL': 300, 'data': '192.168.1.2'},
        <String, dynamic>{'type': 28, 'TTL': 300, 'data': '2001:db8::1'},
        <String, dynamic>{'type': 5, 'TTL': 300, 'data': 'alias.test'},
      ],
    });

    expect(addresses, <String>['75.119.136.143']);
  });

  test('DNS answer lifetime is bounded', () {
    expect(
      dnsJsonLifetime(<String, dynamic>{
        'Answer': <Map<String, dynamic>>[
          <String, dynamic>{'type': 1, 'TTL': 5},
        ],
      }),
      const Duration(minutes: 1),
    );
    expect(
      dnsJsonLifetime(<String, dynamic>{
        'Answer': <Map<String, dynamic>>[
          <String, dynamic>{'type': 1, 'TTL': 86400},
        ],
      }),
      const Duration(hours: 1),
    );
  });

  test(
    'resolver tries independent DoH endpoints and persists the result',
    () async {
      final root = await Directory.systemTemp.createTemp('sql-sync-dns-test-');
      addTearDown(() => root.delete(recursive: true));
      final cacheFile = File('${root.path}${Platform.pathSeparator}cache.json');
      final calls = <String>[];
      final now = DateTime.utc(2026, 8, 23, 12);
      final resolver = ResilientDnsResolver(
        cacheFile: cacheFile,
        nowUtc: () => now,
        fetcher: (endpoint, hostName) async {
          calls.add(endpoint.host);
          if (endpoint.host == 'cloudflare-dns.com') {
            throw const SocketException('injected first resolver outage');
          }
          return <String, dynamic>{
            'Status': 0,
            'Answer': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 1,
                'TTL': 300,
                'data': '75.119.136.143',
              },
            ],
          };
        },
      );

      expect(await resolver.resolve(kLiveSyncHost), <String>['75.119.136.143']);
      expect(calls, <String>['cloudflare-dns.com', 'dns.google']);
      expect(await cacheFile.exists(), isTrue);

      final offlineResolver = ResilientDnsResolver(
        cacheFile: cacheFile,
        nowUtc: () => now.add(const Duration(minutes: 1)),
        fetcher: (_, __) async => throw StateError('DoH must not be called'),
      );
      expect(await offlineResolver.resolve(kLiveSyncHost), <String>[
        '75.119.136.143',
      ]);
    },
  );

  test('resolver combines distinct safe answers from both providers', () async {
    final root = await Directory.systemTemp.createTemp('sql-sync-dns-test-');
    addTearDown(() => root.delete(recursive: true));
    final resolver = ResilientDnsResolver(
      cacheFile: File('${root.path}${Platform.pathSeparator}cache.json'),
      nowUtc: () => DateTime.utc(2026, 8, 23, 12),
      fetcher:
          (endpoint, _) async => <String, dynamic>{
            'Status': 0,
            'Answer': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 1,
                'TTL': endpoint.host == 'cloudflare-dns.com' ? 300 : 120,
                'data':
                    endpoint.host == 'cloudflare-dns.com'
                        ? '75.119.136.143'
                        : '75.119.136.144',
              },
            ],
          },
    );

    expect(await resolver.resolve(kLiveSyncHost), <String>[
      '75.119.136.143',
      '75.119.136.144',
    ]);
  });

  test(
    'validated TLS address is cached without accepting private addresses',
    () async {
      final root = await Directory.systemTemp.createTemp('sql-sync-dns-test-');
      addTearDown(() => root.delete(recursive: true));
      final resolver = ResilientDnsResolver(
        cacheFile: File('${root.path}${Platform.pathSeparator}cache.json'),
        nowUtc: () => DateTime.utc(2026, 8, 23, 12),
        endpoints: const <DnsFallbackEndpoint>[],
      );

      await resolver.rememberValidatedAddress(
        kLiveSyncHost,
        InternetAddress('75.119.136.143'),
      );
      await resolver.rememberValidatedAddress(
        kLiveSyncHost,
        InternetAddress('10.0.0.1'),
      );

      expect(await resolver.cachedAddresses(kLiveSyncHost), <String>[
        '75.119.136.143',
      ]);
    },
  );
}
