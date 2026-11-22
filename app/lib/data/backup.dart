import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/json.dart';
import '../core/workflow.dart';
import 'credentials.dart';
import 'repository.dart';

/// Backs up every workflow and credential into one file, encrypted with a
/// passphrase (PBKDF2-HMAC-SHA256 → AES-256-GCM), and restores it.
class Backup {
  Backup(this.repository, this.credentials);

  static const format = 'flowdroid-backup';
  static const version = 1;
  static const _iterations = 150000;

  final Repository repository;
  final CredentialStore credentials;

  static final _cipher = AesGcm.with256bits();

  Future<Uint8List> export(String passphrase) async {
    final plain = utf8.encode(
      jsonEncode({
        'workflows': (await repository.workflows()).map((w) => w.toJson()).toList(),
        'credentials': (await credentials.all()).map((c) => c.toJson()).toList(),
      }),
    );
    final salt = _randomBytes(16);
    final key = await _key(passphrase, salt, _iterations);
    final box = await _cipher.encrypt(plain, secretKey: key);
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': format,
          'version': version,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'kdf': {'name': 'pbkdf2-sha256', 'iterations': _iterations, 'salt': base64.encode(salt)},
          'nonce': base64.encode(box.nonce),
          'data': base64.encode(box.cipherText),
          'mac': base64.encode(box.mac.bytes),
        }),
      ),
    );
  }

  /// Restores a backup; workflows and credentials with the same id or name are replaced.
  Future<(int workflows, int credentials)> restore(Uint8List file, String passphrase) async {
    final JsonMap doc;
    try {
      doc = asMap(jsonDecode(utf8.decode(file)));
    } on FormatException {
      throw const BackupException('this file is not a FlowDroid backup');
    }
    if (doc['format'] != format) throw const BackupException('this file is not a FlowDroid backup');
    if (asInt(doc['version']) > version) throw const BackupException('this backup is from a newer FlowDroid');
    final kdf = asMap(doc['kdf']);
    final List<int> plain;
    try {
      final key = await _key(passphrase, base64.decode(asString(kdf['salt'])), asInt(kdf['iterations'], _iterations));
      plain = await _cipher.decrypt(
        SecretBox(
          base64.decode(asString(doc['data'])),
          nonce: base64.decode(asString(doc['nonce'])),
          mac: Mac(base64.decode(asString(doc['mac']))),
        ),
        secretKey: key,
      );
    } on SecretBoxAuthenticationError {
      throw const BackupException('wrong passphrase, or the file is damaged');
    } on FormatException {
      throw const BackupException('the backup file is damaged');
    }
    final content = asMap(jsonDecode(utf8.decode(plain)));
    final workflows = asMapList(content['workflows']).map(Workflow.fromJson).toList();
    for (final wf in workflows) {
      await repository.saveWorkflow(wf);
    }
    final creds = asMapList(content['credentials']).map(Credential.fromJson).toList();
    for (final c in creds) {
      await credentials.save(c);
    }
    return (workflows.length, creds.length);
  }

  static Future<SecretKey> _key(String passphrase, List<int> salt, int iterations) => Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  ).deriveKeyFromPassword(password: passphrase, nonce: salt);

  static List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List.generate(n, (_) => r.nextInt(256));
  }
}

class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}
