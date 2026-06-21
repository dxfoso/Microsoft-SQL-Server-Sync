// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

class BrowserPickedTextFile {
  const BrowserPickedTextFile({required this.name, required this.content});

  final String name;
  final String content;
}

String? readBrowserStorage(String key) => html.window.localStorage[key];

void writeBrowserStorage(String key, String value) {
  html.window.localStorage[key] = value;
}

void removeBrowserStorage(String key) {
  html.window.localStorage.remove(key);
}

Future<void> writeBrowserClipboardText(String text) async {
  final clipboard = html.window.navigator.clipboard;
  if (clipboard == null) {
    return;
  }
  await clipboard.writeText(text);
}

void replaceBrowserUrl(String url) {
  html.window.history.replaceState(null, '', url);
}

Future<BrowserPickedTextFile?> pickBrowserTextFile({
  List<String> acceptedExtensions = const <String>['json'],
}) async {
  final input = html.FileUploadInputElement();
  input.accept = acceptedExtensions.map((value) => '.$value').join(',');

  final completer = Completer<BrowserPickedTextFile?>();
  StreamSubscription<html.Event>? changeSubscription;
  StreamSubscription<html.Event>? focusSubscription;
  Timer? focusTimer;
  var handledChange = false;

  changeSubscription = input.onChange.listen((_) {
    handledChange = true;
    final file = input.files?.isNotEmpty == true ? input.files!.first : null;
    if (file == null) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      return;
    }

    final reader = html.FileReader();
    reader.onError.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Failed to read ${file.name}.'));
      }
    });
    reader.onLoadEnd.listen((_) {
      if (!completer.isCompleted) {
        completer.complete(
          BrowserPickedTextFile(
            name: file.name,
            content: (reader.result as String?) ?? '',
          ),
        );
      }
    });
    reader.readAsText(file);
  });

  focusSubscription = html.window.onFocus.listen((_) {
    focusTimer?.cancel();
    focusTimer = Timer(const Duration(milliseconds: 300), () {
      if (!handledChange && !completer.isCompleted) {
        completer.complete(null);
      }
    });
  });

  input.click();
  final result = await completer.future;
  await changeSubscription.cancel();
  await focusSubscription.cancel();
  focusTimer?.cancel();
  return result;
}

Future<void> downloadBrowserTextFile({
  required String filename,
  required String content,
  String mimeType = 'application/json',
}) async {
  final blob = html.Blob(<Object>[content], mimeType);
  final objectUrl = html.Url.createObjectUrlFromBlob(blob);
  final anchor =
      html.AnchorElement(href: objectUrl)
        ..download = filename
        ..style.display = 'none';

  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(objectUrl);
}
