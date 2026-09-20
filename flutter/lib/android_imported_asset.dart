import 'dart:convert';

final class AndroidImportedAsset {
  const AndroidImportedAsset({
    required this.uuid,
    required this.title,
    required this.assetType,
    required this.size,
    required this.checksum,
    required this.localPath,
  });

  factory AndroidImportedAsset.fromMap(Map<String, Object?> value) {
    String requiredString(String key) {
      final result = value[key];
      if (result is! String || result.isEmpty) {
        throw FormatException('Imported asset is missing $key');
      }
      return result;
    }

    final size = value['size'];
    if (size is! int || size <= 0) {
      throw const FormatException('Imported asset has an invalid size');
    }
    return AndroidImportedAsset(
      uuid: requiredString('uuid'),
      title: requiredString('title'),
      assetType: requiredString('assetType'),
      size: size,
      checksum: requiredString('checksum'),
      localPath: requiredString('localPath'),
    );
  }

  final String uuid;
  final String title;
  final String assetType;
  final int size;
  final String checksum;
  final String localPath;

  Map<String, Object?> coreRequest({String? targetBlockId}) {
    final payload = <String, Object?>{
      'uuid': uuid,
      'title': title,
      'assetType': assetType,
      'assetSize': size,
      'assetChecksum': checksum,
      'localPath': localPath,
      if (targetBlockId != null && targetBlockId.isNotEmpty)
        'targetBlockId': targetBlockId,
    };
    return {
      'apiVersion': 1,
      'method': 'dispatch',
      'params': {'action': 'addAsset', 'payload': jsonEncode(payload)},
    };
  }
}
