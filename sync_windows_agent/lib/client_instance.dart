import 'dart:convert';
import 'dart:io';

const String clientInstanceConfigFileName = 'client-instance.json';

class ClientInstanceConfig {
  const ClientInstanceConfig._({this.id, this.displayName});

  const ClientInstanceConfig.defaultInstance() : this._();

  final String? id;
  final String? displayName;

  bool get isDefault => id == null;

  String clientNameFor(String baseName) {
    final normalized =
        baseName.trim().isEmpty ? 'Local Agent' : baseName.trim();
    return isDefault ? normalized : '$normalized--$id';
  }

  String get startupShortcutFileName =>
      isDefault ? 'SQL Sync Agent.lnk' : 'SQL Sync Agent ($id).lnk';

  String get windowLabel =>
      displayName?.trim().isNotEmpty == true ? displayName!.trim() : id ?? '';

  Directory stateDirectory({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final base =
        env['APPDATA'] ?? env['LOCALAPPDATA'] ?? Directory.current.path;
    final root = Directory(
      '$base${Platform.pathSeparator}Microsoft-SQL-Server-Sync',
    );
    return isDefault
        ? root
        : Directory(
          '${root.path}${Platform.pathSeparator}instances'
          '${Platform.pathSeparator}$id',
        );
  }

  static ClientInstanceConfig loadSync({Directory? executableDirectory}) {
    final directory =
        executableDirectory ?? File(Platform.resolvedExecutable).parent;
    final file = File(
      '${directory.path}${Platform.pathSeparator}$clientInstanceConfigFileName',
    );
    if (!file.existsSync()) {
      return const ClientInstanceConfig.defaultInstance();
    }

    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      throw const FormatException(
        'client-instance.json must contain an object.',
      );
    }
    final id = decoded['id']?.toString().trim().toLowerCase() ?? '';
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$').hasMatch(id)) {
      throw const FormatException(
        'client-instance.json id must use 1-32 lowercase letters, numbers, or hyphens.',
      );
    }
    final displayName = decoded['displayName']?.toString().trim();
    return ClientInstanceConfig._(
      id: id,
      displayName: displayName?.isEmpty == true ? null : displayName,
    );
  }
}

final ClientInstanceConfig currentClientInstance =
    ClientInstanceConfig.loadSync();
