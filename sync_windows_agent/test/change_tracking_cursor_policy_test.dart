import 'package:flutter_test/flutter_test.dart';
import 'package:sync_windows_agent/change_tracking_cursor_policy.dart';

void main() {
  test('partial batches keep upload and download cursors unchanged', () {
    expect(
      uploadPreservesChangeTrackingBaseline('server-partial-delta-v3'),
      isTrue,
    );
    expect(
      downloadPreservesChangeTrackingBaseline('server-partial-merge'),
      isTrue,
    );
  });

  test('full all-client batches advance cursors after catch-up', () {
    expect(uploadPreservesChangeTrackingBaseline('server-delta-v3'), isFalse);
    expect(
      uploadPreservesChangeTrackingBaseline('server-union-bootstrap-v3'),
      isFalse,
    );
    expect(downloadPreservesChangeTrackingBaseline('server-merge'), isFalse);
  });

  test('read-only comparison uploads also preserve the cursor', () {
    expect(
      uploadPreservesChangeTrackingBaseline('server-diff-preview'),
      isTrue,
    );
  });

  test('automatic-number inventory preserves the pending delta cursor', () {
    expect(
      uploadPreservesChangeTrackingBaseline(
        'server-range-union-v1:0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15',
      ),
      isTrue,
    );
    expect(
      downloadPreservesChangeTrackingBaseline('server-partial-merge'),
      isTrue,
    );
  });
}
