bool uploadPreservesChangeTrackingBaseline(String sourceClientName) {
  final marker = sourceClientName.trim();
  return marker == 'server-partial-delta-v3' ||
      marker == 'server-diff-preview' ||
      marker ==
          'server-range-union-v1:0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15';
}

bool downloadPreservesChangeTrackingBaseline(String sourceClientName) {
  return sourceClientName.trim() == 'server-partial-merge';
}
