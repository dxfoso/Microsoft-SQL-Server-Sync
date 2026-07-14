class ClientVersion implements Comparable<ClientVersion> {
  const ClientVersion(this.major, this.minor, this.patch, this.build);

  final int major;
  final int minor;
  final int patch;
  final int build;

  static ClientVersion? tryParse(String value) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$',
    ).firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    return ClientVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.tryParse(match.group(4) ?? '') ?? 0,
    );
  }

  @override
  int compareTo(ClientVersion other) {
    for (final comparison in <int>[
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
      build.compareTo(other.build),
    ]) {
      if (comparison != 0) {
        return comparison;
      }
    }
    return 0;
  }
}

bool isStrictlyNewerClientVersion({
  required String current,
  required String candidate,
}) {
  final currentVersion = ClientVersion.tryParse(current);
  final candidateVersion = ClientVersion.tryParse(candidate);
  if (currentVersion == null || candidateVersion == null) {
    return false;
  }
  return candidateVersion.compareTo(currentVersion) > 0;
}
