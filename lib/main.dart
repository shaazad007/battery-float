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
    size: Size(300, 64), minimumSize: Size(160, 48),
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

class _BatteryHomeState extends State<BatteryHome> with TrayListener, WindowListener, SingleTickerProviderStateMixin {
  final Battery _battery = Battery();
  Timer? _poll;
  late final AnimationController _glow;
  double _barWidth = 280;
  double _barHeight = 16;
  double _glowSeconds = 2.0;
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
    _glow = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..repeat();
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
      _compact = false;
      _barWidth = prefs.getDouble('barWidth') ?? 280;
      _barHeight = prefs.getDouble('barHeight') ?? 16;
      _glowSeconds = prefs.getDouble('glowSeconds') ?? 2.0;
      _glow.duration = Duration(milliseconds: (_glowSeconds * 1000).round());
      _glow.repeat();
    });
    await windowManager.setAlwaysOnTop(_alwaysTop);
    await windowManager.setOpacity(_opacity);
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
    await p.setDouble('barWidth', _barWidth);
    await p.setDouble('barHeight', _barHeight);
    await p.setDouble('glowSeconds', _glowSeconds);
  }

  Future<void> _resize() async {
    await windowManager.setMinimumSize(_settings ? const Size(380, 560) : const Size(160, 48));
    await windowManager.setSize(_settings ? const Size(420, 650) : Size(_barWidth + 40, 64));
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
        MenuItem(key: 'settings', label: 'Settings...'),
        MenuItem(key: 'top', label: _alwaysTop ? 'Always on Top: On' : 'Always on Top: Off'),
        MenuItem.separator(),
        MenuItem(key: 'credit', label: 'Developed by Mohammad Shaazad'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Exit Battery Float'),
      ]));
    } catch (e) {
      if (mounted) setState(() => _lastError = 'Tray error: $e');
    }
  }

  Future<void> _showSettings() async {
    setState(() { _settings = true; });
    await windowManager.setOpacity(1.0);
    await _resize();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _closeSettings() async {
    setState(() => _settings = false);
    await _resize();
    await windowManager.setOpacity(_opacity);
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
      case 'top': _toggleTop(); break;
      case 'credit': _showSettings(); break;
      case 'quit': _exit(); break;
    }
  }

  Future<void> _toggleTop() async {
    setState(() => _alwaysTop = !_alwaysTop);
    await windowManager.setAlwaysOnTop(_alwaysTop);
    await _save();
    await _updateTray();
  }

  void _showWidgetMenu(TapDownDetails details) async {
    final position = details.globalPosition;
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(value: 'settings', child: Text('Settings...')),
        PopupMenuItem(value: 'top', child: Text('Always on Top: ${_alwaysTop ? "On" : "Off"}')),
        const PopupMenuDivider(),
        const PopupMenuItem(enabled: false, child: Text('Developed by Mohammad Shaazad')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'exit', child: Text('Exit')),
      ],
    );
    if (selection == 'settings') await _showSettings();
    if (selection == 'top') await _toggleTop();
    if (selection == 'exit') await _exit();
  }

  @override
  void onWindowClose() async {
    if (!_quitting) await windowManager.hide();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _glow.dispose();
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

  bool get _isFull => _level >= 100 || _state == BatteryState.full;
  Color get _glowColor => _isFull || _state == BatteryState.charging
      ? const Color(0xff35ff70)
      : _level <= 20 ? const Color(0xffff3155) : const Color(0xffffa629);

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: _settings ? _settingsPanel() : _floatingBar(),
  );

  Widget _floatingBar() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => windowManager.startDragging(),
    onSecondaryTapDown: _showWidgetMenu,
    child: Center(child: AnimatedBuilder(
      animation: _glow,
      builder: (context, _) {
        final progress = (_level < 0 ? 0.0 : _level / 100).clamp(0.0, 1.0);
        final fullPulse = _isFull ? (0.4 + 0.6 * (1 - (2 * _glow.value - 1).abs())) : 1.0;
        final color = _glowColor;
        return SizedBox(
          width: _barWidth,
          height: _barHeight + 18,
          child: Center(child: Container(
            width: _barWidth, height: _barHeight,
            decoration: BoxDecoration(
              color: const Color(0xff142032).withValues(alpha: .36),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: color.withValues(alpha: .75), width: 1.2),
            ),
            clipBehavior: Clip.antiAlias,
            child: LayoutBuilder(builder: (context, constraints) {
              final fillWidth = constraints.maxWidth * progress;
              return Stack(children: [
                Positioned(left: 0, top: 0, bottom: 0, width: fillWidth,
                  child: Opacity(opacity: fullPulse,
                    child: DecoratedBox(decoration: BoxDecoration(
                      color: color.withValues(alpha: .8),
                      borderRadius: BorderRadius.circular(99),
                      boxShadow: [BoxShadow(color: color, blurRadius: 12)],
                    )),
                  ),
                ),
                if (!_isFull && fillWidth > 2)
                  Positioned(
                    left: (_glow.value * (fillWidth + 38) - 38).clamp(0.0, fillWidth),
                    top: 0, bottom: 0, width: 24,
                    child: DecoratedBox(decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: .85),
                        Colors.white.withValues(alpha: 0),
                      ]),
                    )),
                  ),
              ]);
            }),
          )),
        );
      },
    )),
  );

  Widget _settingsPanel() => Padding(
    padding: const EdgeInsets.all(16),
    child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
      const Text('Bar width'),
      Slider(value: _barWidth, min: 160, max: 480, onChanged: (v) {
        setState(() => _barWidth = v); _save();
      }),
      const Text('Bar thickness'),
      Slider(value: _barHeight, min: 8, max: 30, onChanged: (v) {
        setState(() => _barHeight = v); _save();
      }),
      Text('Glow duration: ${_glowSeconds.toStringAsFixed(1)} s'),
      Slider(value: _glowSeconds, min: 0.6, max: 5, onChanged: (v) {
        setState(() => _glowSeconds = v);
        _glow.duration = Duration(milliseconds: (v * 1000).round());
        _glow.repeat();
        _save();
      }),
      const Text('Developed by Mohammad Shaazad', style: TextStyle(color: Colors.white54)),
      const SizedBox(height: 4),
      const Text('Close (X) hides to tray. Tray menu > Exit quits.',
        style: TextStyle(fontSize: 11, color: Colors.white60)),
      if (_lastError != null) Text(_lastError!, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10, color: Colors.orangeAccent)),
      const SizedBox(height: 12),
      SizedBox(width: double.infinity, child: FilledButton(onPressed: _closeSettings,
        child: const Text('Done'))),
    ])),
  );

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) =>
    SizedBox(height: 44, child: Row(children: [
      Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
      Switch(value: value, onChanged: onChanged),
    ]));
}
