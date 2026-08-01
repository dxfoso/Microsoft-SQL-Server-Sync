bool uploadPreservesChangeTrackingBaseline(String sourceClientName) {
  final marker = sourceClientName.trim();
  return marker == 'server-partial-delta-v3' || marker == 'server-diff-preview';
}

bool downloadPreservesChangeTrackingBaseline(String sourceClientName) {
  return sourceClientName.trim() == 'server-partial-merge';
}
