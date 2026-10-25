import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'backup.dart';

const _taskName = 'tgcloud-auto';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      await BackupService.run(autoMode: true);
      return true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  runApp(const TgCloudApp());
}

class TgCloudApp extends StatelessWidget {
  const TgCloudApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TG Cloud',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2AABEE), useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF2AABEE),
            brightness: Brightness.dark,
            useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _token = TextEditingController();
  final _chat = TextEditingController();
  SharedPreferences? _p;
  String? _botName;
  bool _auto = false, _wifiOnly = true, _busy = false;
  int _doneCount = 0;
  double? _progress;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _p = p;
    _token.text = p.getString('token') ?? '';
    _chat.text = p.getString('chat') ?? '';
    _auto = p.getBool('auto') ?? false;
    _wifiOnly = p.getBool('wifiOnly') ?? true;
    _doneCount = (p.getStringList('done') ?? []).length;
    setState(() {});
    if (_token.text.isNotEmpty) _connect(silent: true);
    if (_auto && _chat.text.isNotEmpty) _runBackup(auto: true);
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _connect({bool silent = false}) async {
    final t = _token.text.trim();
    if (t.isEmpty) return;
    try {
      final me = await Telegram(t).getMe();
      await _p!.setString('token', t);
      setState(() => _botName = '@${me['username']}');
      if (!silent) _snack('Connected to $_botName');
    } catch (e) {
      setState(() => _botName = null);
      if (!silent) _snack('Error: $e');
    }
  }

  Future<void> _detectChat() async {
    try {
      await _connect(silent: true);
      final id = await Telegram(_token.text.trim()).detectChatId();
      if (id == null) {
        _snack('No chat found. Send /start to your bot first, then retry.');
        return;
      }
      _chat.text = id;
      await _p!.setString('chat', id);
      setState(() {});
      _snack('Chat ID saved: $id');
    } catch (e) {
      _snack('Error: $e');
    }
  }

  Future<void> _saveChat() async {
    await _p!.setString('chat', _chat.text.trim());
    _snack('Chat ID saved');
  }

  Future<void> _applySchedule() async {
    await Workmanager().cancelByUniqueName(_taskName);
    if (!_auto) return;
    await Workmanager().registerPeriodicTask(
      _taskName,
      _taskName,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(
          networkType: _wifiOnly ? NetworkType.unmetered : NetworkType.connected),
    );
  }

  Future<void> _toggleAuto(bool v) async {
    if (v) {
      if (_token.text.isEmpty || _chat.text.isEmpty) {
        _snack('Connect your bot and set the chat ID first');
        return;
      }
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.hasAccess) {
        _snack('Storage permission is required');
        return;
      }
      await _p!.setInt('autoSince', DateTime.now().millisecondsSinceEpoch);
    }
    await _p!.setBool('auto', v);
    setState(() => _auto = v);
    await _applySchedule();
  }

  Future<void> _toggleWifi(bool v) async {
    await _p!.setBool('wifiOnly', v);
    setState(() => _wifiOnly = v);
    await _applySchedule();
  }

  Future<void> _runBackup({bool auto = false}) async {
    if (_busy) return;
    if (_token.text.isEmpty || _chat.text.isEmpty) {
      _snack('Connect your bot and set the chat ID first');
      return;
    }
    setState(() {
      _busy = true;
      _progress = null;
      _status = 'Scanning gallery…';
    });
    final r = await BackupService.run(
      autoMode: auto,
      onProgress: (d, t, m) {
        if (!mounted) return;
        setState(() {
          _progress = t == 0 ? null : d / t;
          _status = m;
        });
      },
    );
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = null;
      _doneCount = (p.getStringList('done') ?? []).length;
      _status = r.error != null && r.ok == 0
          ? 'Error: ${r.error}'
          : 'Done — uploaded ${r.ok}, failed ${r.failed}, skipped (>50MB) ${r.skipped}';
    });
  }

  Future<void> _resetHistory() async {
    await _p!.remove('done');
    await _p!.remove('skipped');
    setState(() {
      _doneCount = 0;
      _status = 'Backup history cleared';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TG Cloud')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('1. Connect bot', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Bot token (from @BotFather)',
              helperText: _botName == null ? null : 'Connected: $_botName',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _connect, child: const Text('Connect')),
          const SizedBox(height: 20),
          Text('2. Chat ID', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Send /start to your bot (or add it as admin to a channel), then tap Detect.'),
          const SizedBox(height: 8),
          TextField(
            controller: _chat,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'Chat ID'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: FilledButton.tonal(
                    onPressed: _detectChat, child: const Text('Detect'))),
            const SizedBox(width: 8),
            Expanded(
                child: OutlinedButton(
                    onPressed: _saveChat, child: const Text('Save'))),
          ]),
          const SizedBox(height: 20),
          Text('3. Backup', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto backup'),
            subtitle: const Text('Uploads new photos & videos in the background'),
            value: _auto,
            onChanged: _toggleAuto,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Wi-Fi only (auto backup)'),
            value: _wifiOnly,
            onChanged: _toggleWifi,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : () => _runBackup(),
            icon: const Icon(Icons.cloud_upload),
            label: const Text('Backup now (manual)'),
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress),
          ],
          const SizedBox(height: 12),
          Text(_status),
          const SizedBox(height: 8),
          Text('Backed up so far: $_doneCount files'),
          TextButton(onPressed: _resetHistory, child: const Text('Reset backup history')),
          const SizedBox(height: 8),
          const Text(
            'Files are sent as documents (original quality). Telegram bots can upload up to 50 MB per file; larger videos are skipped.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
