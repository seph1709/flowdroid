import 'package:enough_mail/enough_mail.dart';

import '../core/json.dart';
import '../data/credentials.dart';
import 'file_store.dart';

/// Sends mail over SMTP and reads new mail over IMAP, with an `email` credential.
class EmailService {
  EmailService(this.credentials, {this.files});

  final CredentialStore credentials;

  /// For attachments; null when files aren't available.
  final FileStore? files;

  static const _timeout = Duration(seconds: 30);

  /// The `email` effect: sends each message.
  Future<JsonMap> call(JsonMap effect) async {
    final c = await _credential(asString(effect['credential']));
    final client = SmtpClient('flowdroid.app');
    final port = int.tryParse(c['smtpPort'] ?? '') ?? 465;
    try {
      await client.connectToServer(c['smtpHost'] ?? '', port, isSecure: port == 465, timeout: _timeout);
      await client.ehlo();
      if (port != 465) await client.startTls();
      await client.authenticate(c['email'] ?? '', c['password'] ?? '', AuthMechanism.login);
      final from = MailAddress(c['name'], c['email'] ?? '');
      for (final m in asMapList(effect['messages'])) {
        final to = asString(m['to'])
            .split(',')
            .map((a) => a.trim())
            .where((a) => a.isNotEmpty)
            .map((a) => MailAddress(null, a))
            .toList();
        final builder =
            MessageBuilder.prepareMultipartAlternativeMessage(
                plainText: asBool(m['html']) ? _stripTags(asString(m['text'])) : asString(m['text']),
                htmlText: asBool(m['html']) ? asString(m['text']) : null,
              )
              ..from = [from]
              ..to = to
              ..subject = asString(m['subject']);
        for (final path in asList(m['attachments']).whereType<String>()) {
          final store = files;
          if (store == null) throw const FileStoreException('attachments are not available here');
          final f = await store.existing(path);
          await builder.addFile(f, MediaType.fromText(mimeFromName(f.path)));
        }
        await client.sendMessage(builder.buildMimeMessage());
      }
    } finally {
      await client.quit().catchError((Object _) => SmtpResponse(['221']));
    }
    return const {};
  }

  /// New messages in [mailbox] since the UID in [lastUid] (0 = first check: none, only the latest UID).
  Future<(List<JsonMap>, int)> newMessages(String credentialName, String mailbox, int lastUid) async {
    final c = await _credential(credentialName);
    final client = ImapClient();
    final port = int.tryParse(c['imapPort'] ?? '') ?? 993;
    try {
      await client.connectToServer(c['imapHost'] ?? '', port, isSecure: port == 993, timeout: _timeout);
      if (port != 993) await client.startTls();
      await client.login(c['email'] ?? '', c['password'] ?? '');
      final box = await client.selectMailboxByPath(mailbox.isEmpty ? 'INBOX' : mailbox);
      final next = box.uidNext ?? 0;
      if (lastUid == 0) return (const <JsonMap>[], next > 0 ? next - 1 : 0);
      final search = await client.uidSearchMessages(searchCriteria: 'UID ${lastUid + 1}:*');
      final uids = (search.matchingSequence?.toList() ?? const <int>[]).where((u) => u > lastUid).toList()..sort();
      if (uids.isEmpty) return (const <JsonMap>[], lastUid);
      final fetched = await client.uidFetchMessages(MessageSequence.fromIds(uids, isUid: true), 'BODY.PEEK[]');
      final items = [
        for (final m in fetched.messages)
          {
            'uid': m.uid,
            'from': m.from?.map((a) => a.email).join(', ') ?? '',
            'fromName': m.from?.firstOrNull?.personalName ?? '',
            'to': m.to?.map((a) => a.email).join(', ') ?? '',
            'subject': m.decodeSubject() ?? '',
            'date': m.decodeDate()?.toUtc().toIso8601String(),
            'text': m.decodeTextPlainPart() ?? '',
            'html': m.decodeTextHtmlPart() ?? '',
          },
      ];
      return (items, uids.last);
    } finally {
      await client.logout().catchError((Object _) => null);
    }
  }

  Future<Map<String, String>> _credential(String name) async {
    final c = await credentials.byName(name);
    if (c == null) throw EmailException('credential “$name” not found; add it in Settings → Credentials');
    if (c.type != 'email') throw EmailException('credential “$name” is not an email account');
    return c.values;
  }

  static String _stripTags(String html) => html.replaceAll(RegExp(r'<[^>]*>'), '');
}

class EmailException implements Exception {
  const EmailException(this.message);

  final String message;

  @override
  String toString() => message;
}
