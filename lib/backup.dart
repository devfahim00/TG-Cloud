import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Telegram Bot API (cloud) upload limit is 50 MB per file.
const int maxUploadBytes = 49 * 1024 * 1024;

class Telegram {
  final String token;
  Telegram(this.token);

  Uri _u(String method, [Map<String, String>? q]) =>
      Uri.https('api.telegram.org', '/bot$token/$method', q);

  Future<Map<String, dynamic>> getMe() async {
    final res = await http.get(_u('getMe')).timeout(const Duration(seconds: 30));
    final j = jsonDecode(res.body);
    if (j['ok'] != true) throw Exception(j['description'] ?? 'Invalid token');
    return Map<String, dynamic>.from(j['result']);
  }

  /// Finds the chat id of the latest chat that talked to the bot.
  Future<String?> detectChatId() async {
    final res = await http
        .get(_u('getUpdates', {'limit': '100'}))
        .timeout(const Duration(seconds: 30));
    final j = jsonDecode(res.body);
    if (j['ok'] != true) throw Exception(j['description'] ?? 'getUpdates failed');
    for (final u in (j['result'] as List).reversed) {
      for (final k in ['message', 'channel_post', 'my_chat_member', 'edited_message']) {
        final m = u[k];
        if (m != null && m['chat'] != null) return m['chat']['id'].toString();
      }
    }
    return null;
  }

  Future<void> sendDocument(String chat, File f, String name, {String? caption}) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final req = http.MultipartRequest('POST', _u('sendDocument'))
        ..fields['chat_id'] = chat
        ..fields['disable_content_type_detection'] = 'true';
      if (caption != null) req.fields['caption'] = caption;
      req.files.add(await http.MultipartFile.fromPath('document', f.path, filename: name));
      final res = await http.Response.fromStream(
          await req.send().timeout(const Duration(minutes: 10)));
      final j = jsonDecode(res.body);
      if (j['ok'] == true) return;
      if (res.statusCode == 429) {
        final wait = (j['parameters']?['retry_after'] ?? 5) as int;
        await Future.delayed(Duration(seconds: wait + 1));
        continue;
      }
      throw Exception(j['description'] ?? 'HTTP ${res.statusCode}');
    }
    throw Exception('Too many retries (rate limited)');
  }
}

class BackupResult {
  int ok = 0, failed = 0, skipped = 0;
  String? error;
}

class BackupService {
  static bool running = false;

  /// Backs up media that is not yet in the "done" list.
  /// autoMode: only media created after the moment auto-backup was enabled.
  static Future<BackupResult> run({
    bool autoMode = false,
    void Function(int done, int total, String msg)? onProgress,
  }) async {
    final r = BackupResult();
    if (running) {
      r.error = 'A backup is already running';
      return r;
    }
    running = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      final token = p.getString('token');
      final chat = p.getString('chat');
      if (token == null || chat == null || token.isEmpty || chat.isEmpty) {
        r.error = 'Bot token / chat id not configured';
        return r;
      }

      final perm = autoMode
          ? await PhotoManager.getPermissionState(requestOption: const PermissionRequestOption())
          : await PhotoManager.requestPermissionExtend();
      if (!perm.hasAccess) {
        r.error = 'Storage permission not granted';
        return r;
      }

      final since = autoMode ? (p.getInt('autoSince') ?? DateTime.now().millisecondsSinceEpoch) : 0;
      final done = (p.getStringList('done') ?? []).toSet();
      final skipped = (p.getStringList('skipped') ?? []).toSet();

      final paths = await PhotoManager.getAssetPathList(onlyAll: true, type: RequestType.common);
      if (paths.isEmpty) return r;
      final all = paths.first;
      final total = await all.assetCountAsync;

      // Default order is newest first, so we can stop early in auto mode.
      final pending = <AssetEntity>[];
      for (var page = 0; page * 200 < total; page++) {
        final list = await all.getAssetListPaged(page: page, size: 200);
        var stop = false;
        for (final a in list) {
          if (autoMode && a.createDateTime.millisecondsSinceEpoch < since) {
            stop = true;
            break;
          }
          if (!done.contains(a.id) && !skipped.contains(a.id)) pending.add(a);
        }
        if (stop) break;
      }

      final tg = Telegram(token);
      final queue = pending.reversed.toList(); // oldest first
      for (var i = 0; i < queue.length; i++) {
        final a = queue[i];
        onProgress?.call(i, queue.length, 'Uploading ${i + 1}/${queue.length}');
        try {
          final file = await a.originFile;
          if (file == null) throw Exception('File unavailable');
          if (await file.length() > maxUploadBytes) {
            skipped.add(a.id);
            r.skipped++;
            await p.setStringList('skipped', skipped.toList());
            continue;
          }
          var name = await a.titleAsync;
          if (name.isEmpty) {
            name = '${a.id}.${a.type == AssetType.video ? 'mp4' : 'jpg'}';
          }
          await tg.sendDocument(chat, file, name, caption: name);
          done.add(a.id);
          r.ok++;
          await p.setStringList('done', done.toList());
        } catch (e) {
          r.failed++;
          r.error = e.toString();
        }
      }
      onProgress?.call(queue.length, queue.length, 'Finished');
      return r;
    } catch (e) {
      r.error = e.toString();
      return r;
    } finally {
      running = false;
    }
  }
}
