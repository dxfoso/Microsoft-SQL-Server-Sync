import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/delta_package.dart';

void main() {
  test('1200 changed rows use twelve memory-bounded compressed packages', () {
    final rows = List.generate(
      1200,
      (index) => <String, String?>{
        'Id': '$index',
        'Name': 'Changed row $index',
        '__sync_op': 'U',
        '__sync_operation_id': index.toRadixString(16).padLeft(64, '0'),
      },
    );

    final packages = buildCompressedDeltaPackages(rows);

    expect(packages, hasLength(12));
    expect(packages.every((value) => value.rowCount == 100), isTrue);
    expect(
      packages.every(
        (value) =>
            value.uncompressedBytes <= kDeltaPackageMaxUncompressedBytes &&
            value.compressedBytes <= kDeltaPackageMaxCompressedBytes,
      ),
      isTrue,
    );
  });

  test('compressed packages round-trip Unicode rows and delete tombstones', () {
    final rows = <Map<String, String?>>[
      {
        'Id': '1',
        'Name': 'مرحبا 🌍',
        '__sync_op': 'U',
        '__sync_operation_id': 'a' * 64,
      },
      {
        'Id': '2',
        'Name': null,
        '__sync_op': 'D',
        '__sync_operation_id': 'b' * 64,
      },
    ];

    final package = buildCompressedDeltaPackages(rows).single;
    final decoded = jsonDecode(
      utf8.decode(gzip.decode(base64Decode(package.payloadBase64))),
    );

    expect(decoded, rows);
  });

  test('a single oversized row fails closed', () {
    final rows = <Map<String, String?>>[
      {'Id': '1', 'Payload': 'x' * 1024},
    ];

    expect(
      () => buildCompressedDeltaPackages(
        rows,
        maxUncompressedBytes: 128,
        maxCompressedBytes: 128,
      ),
      throwsStateError,
    );
  });

  test('adaptive gzip levels preserve the exact payload', () {
    final rows = List.generate(
      80,
      (index) => <String, String?>{
        'Id': '$index',
        'Arabic': 'السلام عليكم $index',
        '__sync_op': 'U',
        '__sync_operation_id': index.toRadixString(16).padLeft(64, '0'),
      },
    );

    for (final level in [1, 6]) {
      final package =
          buildCompressedDeltaPackages(rows, gzipLevel: level).single;
      expect(
        jsonDecode(
          utf8.decode(gzip.decode(base64Decode(package.payloadBase64))),
        ),
        rows,
      );
    }
  });
}
