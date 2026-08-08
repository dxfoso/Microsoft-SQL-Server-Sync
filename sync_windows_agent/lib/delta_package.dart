import 'dart:convert';
import 'dart:io';

// The server's durable winner evaluation keeps several identity projections
// per row. Keep each request bounded below the 128 MiB interpreter budget.
const int kDeltaPackageMaxRows = 100;
const int kDeltaPackageMaxUncompressedBytes = 512000;
const int kDeltaPackageMaxCompressedBytes = 384000;

class CompressedDeltaPackage {
  const CompressedDeltaPackage({
    required this.startOffset,
    required this.endOffset,
    required this.rowCount,
    required this.uncompressedBytes,
    required this.compressedBytes,
    required this.payloadBase64,
  });

  final int startOffset;
  final int endOffset;
  final int rowCount;
  final int uncompressedBytes;
  final int compressedBytes;
  final String payloadBase64;
}

Iterable<CompressedDeltaPackage> buildCompressedDeltaPackages(
  List<Map<String, String?>> rows, {
  int maxRows = kDeltaPackageMaxRows,
  int maxUncompressedBytes = kDeltaPackageMaxUncompressedBytes,
  int maxCompressedBytes = kDeltaPackageMaxCompressedBytes,
}) sync* {
  if (maxRows <= 0 || maxUncompressedBytes <= 0 || maxCompressedBytes <= 0) {
    throw ArgumentError('Delta package limits must be positive.');
  }

  var offset = 0;
  do {
    var end =
        rows.isEmpty
            ? 0
            : (offset + maxRows < rows.length ? offset + maxRows : rows.length);
    late List<int> uncompressed;
    late List<int> compressed;
    while (true) {
      uncompressed = utf8.encode(jsonEncode(rows.sublist(offset, end)));
      compressed = gzip.encode(uncompressed);
      final withinBounds =
          uncompressed.length <= maxUncompressedBytes &&
          compressed.length <= maxCompressedBytes;
      if (withinBounds) {
        break;
      }
      if (end <= offset + 1) {
        throw StateError(
          'One changed row exceeds the bounded compressed delta package limit.',
        );
      }
      end--;
    }
    yield CompressedDeltaPackage(
      startOffset: offset,
      endOffset: end,
      rowCount: end - offset,
      uncompressedBytes: uncompressed.length,
      compressedBytes: compressed.length,
      payloadBase64: base64Encode(compressed),
    );
    offset = end;
  } while (offset < rows.length);
}
