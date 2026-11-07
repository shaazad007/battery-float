import 'dart:async';
import 'dart:io';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Windows desktop only')))));
    return;
  }
  await windowManager.ensureInitialized();
  await localNotifier.setup(appName: 'Battery Float', shortcutPolicy: ShortcutPolicy.requireCreate);
  const options = WindowOptions(
    size: Size(260, 150), minimumSize: Size(240, 120),
    center: false, backgroundColor: Colors.transparent,
    skipTaskbar: true, titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setPosition(const Offset(60, 90));
    await windowManager.show();
  });
  runApp(const BatteryApp());
}

class BatteryApp extends StatelessWidget {
  const BatteryApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Battery Float', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    home: const BatteryHome(),
  );
}

class BatteryHome extends StatefulWidget {
  const BatteryHome({super.key});
  @override
  State<BatteryHome> createState() => _BatteryHomeState();
}

class _BatteryHomeState extends State<BatteryHome> with TrayListener, WindowListener {
  final Battery _battery = Battery();
  Timer? _poll;
  int _level = -1;
  BatteryState _state = BatteryState.unknown;
  Set<int> _alerts = {10, 20, 50};
  final Set<int> _fired = {};
  double _opacity = 0.78;
  bool _alwaysTop = true;
  bool _sound = true;
  bool _compact = false;
  bool _settings = false;
  bool _quitting = false;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _initialize();
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _alerts = (prefs.getStringList('alerts') ?? ['10', '20', '50'])
          .map(int.tryParse).whereType<int>().toSet();
      _opacity = prefs.getDouble('opacity') ?? 0.78;
      _alwaysTop = prefs.getBool('alwaysTop') ?? true;
      _sound = prefs.getBool('sound') ?? true;
      _compact = prefs.getBool('compact') ?? false;
    });
    await windowManager.setAlwaysOnTop(_alwaysTop);
    await _resize();
    await _updateTray();
    await _refresh();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('alerts', _alerts.map((e) => '$e').toList());
    await p.setDouble('opacity', _opacity);
    await p.setBool('alwaysTop', _alwaysTop);
    await p.setBool('sound', _sound);
    await p.setBool('compact', _compact);
  }

  Future<void> _resize() async {
    await windowManager.setSize(_settings ? const Size(330, 490) :
      _compact ? const Size(180, 74) : const Size(260, 150));
  }

  Future<void> _refresh() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (!mounted) return;
      final previous = _level;
      setState(() { _level = level; _state = state; _lastError = null; });
      // Only notify when a threshold is crossed downwards, never on first startup.
      if (state == BatteryState.discharging) {
        if (previous >= 0 && level < previous) {
          for (final threshold in _alerts.toList()..sort((a, b) => b.compareTo(a))) {
            if (previous > threshold && level <= threshold && !_fired.contains(threshold)) {
              _fired.add(threshold);
              await _notify(threshold);
            }
          }
        }
        // Re-arm levels after charge rises above the threshold.
        _fired.removeWhere((threshold) => level > threshold);
      } else {
        _fired.clear();
      }
      await _updateTray();
    } catch (e) {
      if (mounted) setState(() => _lastError = '$e');
    }
  }

  Future<void> _notify(int threshold) async {
    try {
      if (_sound) SystemSound.play(SystemSoundType.alert);
      final n = LocalNotification(
        title: 'Battery low: $_level%',
        body: 'Battery reached your $threshold% alert level. Connect your charger.',
      );
      await n.show();
    } catch (e) {
      if (mounted) setState(() => _lastError = 'Notification error: $e');
    }
  }

  Future<void> _updateTray() async {
    try {
      // Windows tray icon requires an .ico file, shipped in assets.
      await trayManager.setIcon('assets/battery.ico');
      await trayManager.setToolTip('Battery Float: ${_level < 0 ? "Reading" : "$_level%"}');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Show widget'),
        MenuItem(key: 'settings', label: 'Settings'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Exit Battery Float'),
      ]));
    } catch (e) {
      if (mounted) setState(() => _lastError = 'Tray error: $e');
    }
  }

  Future<void> _showSettings() async {
    setState(() { _settings = true; _compact = false; });
    await _resize();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _closeSettings() async {
    setState(() => _settings = false);
    await _resize();
  }

  Future<void> _exit() async {
    _quitting = true;
    _poll?.cancel();
    await trayManager.destroy();
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show': windowManager.show(); break;
      case 'settings': _showSettings(); break;
      case 'quit': _exit(); break;
    }
  }

  @override
  void onWindowClose() async {
    if (!_quitting) await windowManager.hide();
  }

  @override
  void dispose() {
    _poll?.cancel();
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  Color get _batteryColor => _level <= 20 ? const Color(0xffff6b6b) :
      _level <= 50 ? const Color(0xffffc66d) : const Color(0xff5ee0ae);
  String get _stateText => switch (_state) {
    BatteryState.charging => 'Charging',
    BatteryState.full => 'Fully charged',
    BatteryState.discharging => 'On battery',
    _ => 'Checking status',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: const Color(0xff101827).withValues(alpha: _opacity),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: .19)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .18), blurRadius: 12)],
        ),
        child: _settings ? _settingsPanel() : _widgetPanel(),
      ),
    );
  }

  Widget _widgetPanel() => Column(children: [
    GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 7, 0),
        child: Row(children: [
          const Icon(Icons.drag_indicator, size: 17, color: Colors.white54),
          const Spacer(),
          InkWell(onTap: _showSettings, child: const Icon(Icons.settings_outlined, size: 17)),
          const SizedBox(width: 12),
          InkWell(onTap: () => windowManager.hide(), child: const Icon(Icons.close, size: 17)),
        ]),
      ),
    ),
    Expanded(child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(_state == BatteryState.charging ? Icons.battery_charging_full : Icons.battery_full,
              size: _compact ? 23 : 32, color: _batteryColor),
          const SizedBox(width: 8),
          Text(_level < 0 ? '--%' : '$_level%', style: TextStyle(
            fontSize: _compact ? 24 : 37, fontWeight: FontWeight.w800, color: Colors.white)),
        ]),
        if (!_compact) ...[
          const SizedBox(height: 4),
          Text(_stateText, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 8),
          ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(
            value: _level < 0 ? 0 : _level / 100, minHeight: 6,
            backgroundColor: Colors.white24, valueColor: AlwaysStoppedAnimation(_batteryColor),
          )),
        ],
      ]),
    )),
  ]);

  Widget _settingsPanel() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Battery Float Settings', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
        IconButton(onPressed: _closeSettings, icon: const Icon(Icons.close)),
      ]),
      const Text('Alert when battery falls to:', style: TextStyle(fontSize: 13)),
      Wrap(spacing: 4, runSpacing: 0, children: [10, 20, 30, 40, 50, 60, 70, 80, 90].map((n) =>
        FilterChip(label: Text('$n%'), selected: _alerts.contains(n),
          onSelected: (v) { setState(() { if (v) { _alerts.add(n); } else { _alerts.remove(n); } }); _save(); }),
      ).toList()),
      const SizedBox(height: 8),
      Text('Widget opacity: ${(_opacity * 100).round()}%'),
      Slider(value: _opacity, min: .25, max: 1, divisions: 15, onChanged: (v) {
        setState(() => _opacity = v); _save();
      }),
      _switch('Always on top', _alwaysTop, (v) async {
        setState(() => _alwaysTop = v); await windowManager.setAlwaysOnTop(v); await _save();
      }),
      _switch('Play alert sound', _sound, (v) { setState(() => _sound = v); _save(); }),
      _switch('Compact floating pill', _compact, (v) { setState(() => _compact = v); _save(); }),
      const SizedBox(height: 4),
      const Text('Close (X) hides to tray. Tray menu > Exit quits.',
        style: TextStyle(fontSize: 11, color: Colors.white60)),
      if (_lastError != null) Text(_lastError!, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10, color: Colors.orangeAccent)),
      const Spacer(),
      SizedBox(width: double.infinity, child: FilledButton(onPressed: _closeSettings,
        child: const Text('Done'))),
    ]),
  );

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) =>
    SizedBox(height: 44, child: Row(children: [
      Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
      Switch(value: value, onChanged: onChanged),
    ]));
}
