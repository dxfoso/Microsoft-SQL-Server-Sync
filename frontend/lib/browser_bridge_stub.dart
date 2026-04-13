class BrowserPickedTextFile {
  const BrowserPickedTextFile({required this.name, required this.content});

  final String name;
  final String content;
}

final Map<String, String> _memoryStorage = <String, String>{};

String? readBrowserStorage(String key) => _memoryStorage[key];

void writeBrowserStorage(String key, String value) {
  _memoryStorage[key] = value;
}

void removeBrowserStorage(String key) {
  _memoryStorage.remove(key);
}

Future<BrowserPickedTextFile?> pickBrowserTextFile({
  List<String> acceptedExtensions = const <String>['json'],
}) async {
  return null;
}

Future<void> downloadBrowserTextFile({
  required String filename,
  required String content,
  String mimeType = 'application/json',
}) async {}
