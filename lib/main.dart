import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:battery_plus/battery_plus.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

typedef _GetIfTableNative = Uint32 Function(Pointer<Uint8>, Pointer<Uint32>, Int32);
typedef _GetIfTableDart = int Function(Pointer<Uint8>, Pointer<Uint32>, int);

// Windows IP Helper API. MIB_IFROW uses 32-bit octet counters, sampled at 500 ms.
class NetworkSampler {
  late final _GetIfTableDart _getIfTable = DynamicLibrary.open('iphlpapi.dll')
      .lookupFunction<_GetIfTableNative, _GetIfTableDart>('GetIfTable');
  int? _lastIn, _lastOut;
  DateTime? _lastTime;
  (double, double) sample() {
    final size = calloc<Uint32>();
    try {
      _getIfTable(nullptr, size, 0);
      if (size.value < 4 || size.value > 20000000) return (0, 0);
      final buffer = calloc<Uint8>(size.value);
      try {
        if (_getIfTable(buffer, size, 0) != 0) return (0, 0);
        final bytes = buffer.asTypedList(size.value);
        final data = ByteData.sublistView(bytes);
        final count = data.getUint32(0, Endian.little);
        int incoming = 0, outgoing = 0;
        for (int i = 0; i < count && 4 + (i + 1) * 860 <= bytes.length; i++) {
          final offset = 4 + i * 860;
          final type = data.getUint32(offset + 516, Endian.little);
          final status = data.getUint32(offset + 544, Endian.little);
          if (type == 24 || status != 1) continue; // exclude loopback and down adapters
          incoming += data.getUint32(offset + 552, Endian.little);
          outgoing += data.getUint32(offset + 576, Endian.little);
        }
        final now = DateTime.now();
        final elapsed = _lastTime == null ? 0.0 : now.difference(_lastTime!).inMilliseconds / 1000.0;
        double down = 0, up = 0;
        if (_lastIn != null && elapsed > 0) {
          // Reset/wrap or adapter changes are clamped to zero.
          final d = incoming - _lastIn!;
          final u = outgoing - _lastOut!;
          if (d >= 0 && d < 500000000) down = d / elapsed;
          if (u >= 0 && u < 500000000) up = u / elapsed;
        }
        _lastIn = incoming;
        _lastOut = outgoing;
        _lastTime = now;
        return (down, up);
      } finally { calloc.free(buffer); }
    } finally { calloc.free(size); }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('Windows desktop only')))));
    return;
  }
  await windowManager.ensureInitialized();
  try { await localNotifier.setup(appName: 'Battery Float'); } catch (_) {}
  const opts = WindowOptions(size: Size(740, 76), minimumSize: Size(320, 60),
    backgroundColor: Colors.transparent, skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden, alwaysOnTop: true);
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.setAsFrameless();
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setPosition(const Offset(80, 80));
    await windowManager.show();
  });
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: BatteryFloat(),
    title: 'Battery Float V3'));
}

class BatteryFloat extends StatefulWidget {
  const BatteryFloat({super.key});
  @override State<BatteryFloat> createState() => _BatteryFloatState();
}

class _BatteryFloatState extends State<BatteryFloat> with TrayListener, WindowListener, SingleTickerProviderStateMixin {
  final _battery = Battery();
  final _net = NetworkSampler();
  late final AnimationController _animation;
  Timer? _networkTimer, _batteryTimer;
  int level = 0;
  BatteryState batteryState = BatteryState.unknown;
  double download = 0, upload = 0;
  double maxBytes = 2 * 1024 * 1024;
  double maxInput = 2;
  String maxUnit = 'MB/s', displayUnit = 'Auto', mode = 'both', speedDisplay = 'both';
  double refreshSeconds = .5, opacity = 1, thickness = 12, glow = .7;
  bool alwaysTop = true, sound = true, settings = false, startWithWindows = false;
  Set<int> alerts = {10, 20, 50};
  final Set<int> fired = {};
  Offset? oldPosition;
  int previousLevel = -1;
  String page = 'General';
  bool busy = false;
  final TextEditingController maxController = TextEditingController(text: '2');

  @override void initState() {
    super.initState();
    _animation = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      opacity = (p.getDouble('v3.opacity') ?? 1).clamp(.2, 1);
      maxInput = p.getDouble('v3.maxInput') ?? 2;
      maxUnit = p.getString('v3.maxUnit') ?? 'MB/s';
      displayUnit = p.getString('v3.displayUnit') ?? 'Auto';
      mode = p.getString('v3.mode') ?? 'both';
      speedDisplay = p.getString('v3.speedDisplay') ?? 'both';
      refreshSeconds = p.getDouble('v3.refresh') ?? .5;
      thickness = p.getDouble('v3.thickness') ?? 12;
      glow = p.getDouble('v3.glow') ?? .7;
      alwaysTop = p.getBool('v3.alwaysTop') ?? true;
      sound = p.getBool('v3.sound') ?? true;
      alerts = (p.getStringList('v3.alerts') ?? ['10', '20', '50']).map(int.tryParse).whereType<int>().toSet();
      maxController.text = maxInput.toString();
    });
    _updateMax();
    await windowManager.setAlwaysOnTop(alwaysTop);
    await windowManager.setOpacity(opacity);
    final x = p.getDouble('v3.x'), y = p.getDouble('v3.y');
    if (x != null && y != null) await windowManager.setPosition(Offset(x, y));
    await _tray();
    await _readBattery();
    _batteryTimer = Timer.periodic(const Duration(seconds: 10), (_) => _readBattery());
    _startNetwork();
  }

  double _asBytes(double value, String unit) {
    switch (unit) {
      case 'KB/s': return value * 1024;
      case 'MB/s': return value * 1024 * 1024;
      case 'Kbps': return value * 1000 / 8;
      case 'Mbps': return value * 1000000 / 8;
      default: return value;
    }
  }
  void _updateMax() => maxBytes = math.max(1, _asBytes(maxInput, maxUnit));
  String _format(double bytes) {
    if (displayUnit == 'KB/s') return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
    if (displayUnit == 'MB/s') return '${(bytes / 1048576).toStringAsFixed(2)} MB/s';
    if (displayUnit == 'Kbps') return '${(bytes * 8 / 1000).toStringAsFixed(0)} Kbps';
    if (displayUnit == 'Mbps') return '${(bytes * 8 / 1000000).toStringAsFixed(2)} Mbps';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(2)} MB/s';
    return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
  }
  void _startNetwork() {
    _networkTimer?.cancel();
    _networkTimer = Timer.periodic(Duration(milliseconds: (refreshSeconds * 1000).round()), (_) {
      try {
        final (d, u) = _net.sample();
        if (mounted) setState(() { download = d; upload = u; });
      } catch (_) { /* Keep widget alive if an adapter disappears. */ }
    });
  }
  Future<void> _readBattery() async {
    try {
      final l = await _battery.batteryLevel;
      final s = await _battery.batteryState;
      if (!mounted) return;
      setState(() { level = l; batteryState = s; });
      if (previousLevel >= 0 && s == BatteryState.discharging && l < previousLevel) {
        for (final t in alerts) {
          if (previousLevel > t && l <= t && !fired.contains(t)) {
            fired.add(t);
            if (sound) SystemSound.play(SystemSoundType.alert);
            try { await LocalNotification(title: 'Battery low: $l%', body: 'Battery reached $t%.').show(); } catch (_) {}
          }
        }
      }
      fired.removeWhere((t) => l > t);
      previousLevel = l;
      await _tray();
    } catch (_) {}
  }
  Future<void> _tray() async {
    try {
      await trayManager.setIcon('assets/battery.ico');
      await trayManager.setToolTip('Battery Float V3: $level% | ↓ ${_format(download)}');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'settings', label: 'Settings...'),
        MenuItem(key: 'battery', label: 'Show Battery Bar: ${mode != 'network' ? 'On' : 'Off'}'),
        MenuItem(key: 'bandwidth', label: 'Show Bandwidth Bar: ${mode != 'battery' ? 'On' : 'Off'}'),
        MenuItem(key: 'top', label: 'Always on Top: ${alwaysTop ? 'On' : 'Off'}'),
        MenuItem.separator(),
        MenuItem(key: 'credit', label: 'Developed by Mohammad Shaazad'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Exit'),
      ]));
    } catch (_) {}
  }
  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('v3.opacity', opacity);
    await p.setDouble('v3.maxInput', maxInput);
    await p.setString('v3.maxUnit', maxUnit);
    await p.setString('v3.displayUnit', displayUnit);
    await p.setString('v3.mode', mode);
    await p.setString('v3.speedDisplay', speedDisplay);
    await p.setDouble('v3.refresh', refreshSeconds);
    await p.setDouble('v3.thickness', thickness);
    await p.setDouble('v3.glow', glow);
    await p.setBool('v3.alwaysTop', alwaysTop);
    await p.setBool('v3.sound', sound);
    await p.setStringList('v3.alerts', alerts.map((e) => '$e').toList());
  }
  Future<void> _openSettings() async {
    if (settings || busy) return;
    busy = true;
    oldPosition = await windowManager.getPosition();
    await windowManager.setOpacity(1);
    await windowManager.setMinimumSize(const Size(780, 550));
    await windowManager.setSize(const Size(900, 610));
    await windowManager.center();
    await windowManager.setSkipTaskbar(false);
    if (mounted) setState(() { settings = true; page = 'General'; });
    await windowManager.show();
    await windowManager.focus();
    busy = false;
  }
  Future<void> _closeSettings() async {
    if (!settings || busy) return;
    busy = true;
    await _save();
    setState(() => settings = false);
    await windowManager.setMinimumSize(const Size(320, 60));
    await windowManager.setSize(const Size(740, 76));
    if (oldPosition != null) await windowManager.setPosition(oldPosition!);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setOpacity(opacity);
    busy = false;
  }
  Future<void> _quit() async {
    _networkTimer?.cancel(); _batteryTimer?.cancel();
    await trayManager.destroy();
    await windowManager.destroy();
  }
  @override void onTrayIconMouseDown() => windowManager.show();
  @override void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'settings': _openSettings(); break;
      case 'top': _toggleTop(); break;
      case 'battery': setState(() => mode = mode == 'battery' ? 'both' : 'network'); _save(); _tray(); break;
      case 'bandwidth': setState(() => mode = mode == 'network' ? 'both' : 'battery'); _save(); _tray(); break;
      case 'credit': _openSettings(); break;
      case 'exit': _quit(); break;
    }
  }
  Future<void> _toggleTop() async {
    setState(() => alwaysTop = !alwaysTop);
    await windowManager.setAlwaysOnTop(alwaysTop);
    await _save(); await _tray();
  }
  @override void onWindowClose() => _quit();
  @override void onWindowMove() async {
    if (settings) return;
    final pos = await windowManager.getPosition();
    final p = await SharedPreferences.getInstance();
    await p.setDouble('v3.x', pos.dx); await p.setDouble('v3.y', pos.dy);
  }
  @override void dispose() {
    _networkTimer?.cancel(); _batteryTimer?.cancel(); _animation.dispose(); maxController.dispose();
    trayManager.removeListener(this); windowManager.removeListener(this);
    super.dispose();
  }

  Color get batteryColor => level <= 20 && batteryState == BatteryState.discharging
      ? const Color(0xffff3157) : batteryState == BatteryState.charging || level == 100
      ? const Color(0xff19ff55) : const Color(0xffffa522);

  Widget _meter(double value, Color color, {double? height, bool pulse = false}) {
    return AnimatedBuilder(animation: _animation, builder: (context, _) {
      final position = _animation.value;
      final intensity = pulse ? .45 + .55 * math.sin(position * math.pi).abs() : 1.0;
      return Container(height: height ?? thickness, decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(50), border: Border.all(color: color.withValues(alpha: .8)),
        color: const Color(0xff15283c)),
        child: ClipRRect(borderRadius: BorderRadius.circular(50), child: Stack(children: [
          FractionallySizedBox(widthFactor: value.clamp(0.0, 1.0), child: Container(
            decoration: BoxDecoration(gradient: LinearGradient(colors: [color.withValues(alpha: .65 * intensity), color.withValues(alpha: intensity)]),
              boxShadow: [BoxShadow(color: color.withValues(alpha: glow * intensity), blurRadius: 14)]))),
          if (value > 0.02) Positioned.fill(child: FractionallySizedBox(alignment: Alignment.centerLeft,
            widthFactor: value.clamp(0.0, 1.0), child: Align(alignment: Alignment(-1 + 2 * position, 0),
              child: Container(width: 25, decoration: BoxDecoration(gradient: RadialGradient(colors: [Colors.white.withValues(alpha: .8 * intensity), color.withValues(alpha: 0)]))))))
        ])));
    });
  }
  Widget _floatView() {
    final showBattery = mode != 'network';
    final showNet = mode != 'battery';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => windowManager.startDragging(),
      onSecondaryTapDown: (_) => trayManager.popUpContextMenu(),
      child: Container(margin: const EdgeInsets.all(7), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(color: const Color(0xff06182c), borderRadius: BorderRadius.circular(50),
          border: Border.all(color: const Color(0xff25c9ff), width: 1.3),
          boxShadow: const [BoxShadow(color: Color(0x8825c9ff), blurRadius: 12)]),
        child: Row(children: [
          if (showBattery) ...[
            Icon(Icons.bolt, color: batteryColor, size: 25), const SizedBox(width: 8),
            Expanded(flex: 3, child: _meter(level / 100, batteryColor, pulse: level == 100)),
          ],
          if (showBattery && showNet) const Padding(padding: EdgeInsets.symmetric(horizontal: 14), child: Text('│', style: TextStyle(color: Colors.white54))),
          if (showNet) ...[
            const Icon(Icons.signal_cellular_alt, color: Color(0xff16dfff), size: 22), const SizedBox(width: 8),
            Expanded(flex: 3, child: _meter((speedDisplay == 'upload' ? upload : download) / maxBytes, const Color(0xff00cfff))),
            const SizedBox(width: 12),
            if (speedDisplay != 'upload') Text('↓ ${_format(download)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
            if (speedDisplay == 'both') const Padding(padding: EdgeInsets.symmetric(horizontal: 9), child: Text('│', style: TextStyle(color: Colors.white54))),
            if (speedDisplay != 'download') Text('↑ ${_format(upload)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xff31e8ff))),
          ]
        ])),
    );
  }

  Widget _choice(String selected, List<String> values, ValueChanged<String> change, {Map<String, String>? labels}) =>
    Wrap(spacing: 7, runSpacing: 7, children: values.map((v) => ChoiceChip(label: Text(labels?[v] ?? v, style: const TextStyle(fontSize: 12)),
      selected: selected == v, onSelected: (_) { setState(() => change(v)); _save(); },
      selectedColor: const Color(0xff0564bb), backgroundColor: const Color(0xff0a1c31),
      side: BorderSide(color: selected == v ? const Color(0xff00d7ff) : Colors.white24))).toList());
  Widget _section(String name, Widget child) => Container(padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: const Color(0xff0b2037), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xff2273a0))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)), const SizedBox(height: 12), child]));
  Widget _slider(String label, double value, double min, double max, ValueChanged<double> change, String suffix) =>
    Row(children: [SizedBox(width: 140, child: Text(label, style: const TextStyle(fontSize: 12))),
      Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: (v) { setState(() => change(v)); _save(); })),
      SizedBox(width: 55, child: Text('${value.round()}$suffix', textAlign: TextAlign.right))]);
  Widget _toggle(String title, bool value, ValueChanged<bool> change) => SwitchListTile(dense: true, contentPadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(fontSize: 13)), value: value, onChanged: (v) { setState(() => change(v)); _save(); });

  Widget _general() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _section('Display Mode (Combined Widget)', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _choice(mode, ['both', 'battery', 'network'], (v) => mode = v, labels: {'both':'Battery + Bandwidth', 'battery':'Battery Only', 'network':'Bandwidth Only'}),
      const SizedBox(height: 10), const Text('Bandwidth Display'),
      _choice(speedDisplay, ['both','download','upload'], (v) => speedDisplay = v, labels: {'both':'Both (Download + Upload)', 'download':'Download Only', 'upload':'Upload Only'}),
      const SizedBox(height: 10), const Text('Speed Unit'),
      _choice(displayUnit, ['Auto','KB/s','Kbps','MB/s','Mbps'], (v) => displayUnit = v),
      const SizedBox(height: 10), Row(children: [const Text('My Internet Speed (Max):  '),
        SizedBox(width: 100, child: TextField(controller: maxController, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
          onChanged: (v) { final n = double.tryParse(v); if (n != null && n > 0) { setState(() { maxInput = n; _updateMax(); }); _save(); } })),
        const SizedBox(width: 8), DropdownButton<String>(value: maxUnit, items: ['KB/s','Kbps','MB/s','Mbps'].map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
          onChanged: (v) { if (v != null) { setState(() { maxUnit = v; _updateMax(); }); _save(); } }),
      ]),
      const SizedBox(height: 8), const Text('Refresh Interval'),
      _choice(refreshSeconds.toString(), ['0.5','1.0','2.0'], (v) { refreshSeconds = double.parse(v); _startNetwork(); }, labels: {'0.5':'0.5 sec','1.0':'1 sec','2.0':'2 sec'}),
    ])), const SizedBox(height: 12),
    _section('Widget Appearance', Column(children: [
      _slider('Bar Thickness', thickness, 6, 24, (v) => thickness = v, 'px'),
      _slider('Opacity', opacity * 100, 20, 100, (v) => opacity = v / 100, '%'),
      _slider('Glow Intensity', glow * 100, 0, 100, (v) => glow = v / 100, '%'),
    ])), const SizedBox(height: 12),
    _section('Colors & Behavior', const Wrap(spacing: 14, children: [
      Text('🟢 Charging'), Text('🟠 Discharging'), Text('🔴 Low (≤20%)'), Text('🔵 Bandwidth')
    ])),
  ]);
  Widget _other() {
    if (page == 'Alerts') return _section('Low Battery Notifications', Column(children: [
      ...[10,20,30,40,50].map((t) => CheckboxListTile(title: Text('$t%'), value: alerts.contains(t),
        onChanged: (v) { setState(() { if (v == true) { alerts.add(t); } else { alerts.remove(t); } }); _save(); })),
      _toggle('Notification sound', sound, (v) => sound = v),
    ]));
    if (page == 'Behavior') return _section('Behavior', Column(children: [
      _toggle('Always on Top', alwaysTop, (v) { alwaysTop = v; windowManager.setAlwaysOnTop(v); }),
      const Text('Start with Windows: create a shortcut to the EXE in shell:startup.\nAuto-start is not enabled automatically.', style: TextStyle(color: Colors.white70)),
    ]));
    if (page == 'About') return _section('About', const Text('Battery Float V3\nDeveloped by Mohammad Shaazad\nWindows 10 / 11 desktop application'));
    if (page == 'Battery') return _section('Battery', Text('Battery: $level%\nStatus: ${batteryState.name}\nGreen charging / orange discharging / red low / full-charge pulse'));
    if (page == 'Bandwidth') return _section('Bandwidth', Text('Download: ${_format(download)}\nUpload: ${_format(upload)}\nMaximum: $maxInput $maxUnit\nMeasures local network adapter traffic, not ISP speed-test results.'));
    return _section(page, const Text('Widget is draggable. Right-click to open Settings. The window is centered and opaque.'));
  }
  Widget _settingsView() => Container(color: const Color(0xff050f20), child: Column(children: [
    Container(height: 52, padding: const EdgeInsets.symmetric(horizontal: 18), color: const Color(0xff081b33),
      child: Row(children: [const Icon(Icons.bolt, color: Color(0xff25ff66)), const SizedBox(width: 12),
        const Expanded(child: Text('Battery Float V3 – Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
        IconButton(onPressed: _closeSettings, icon: const Icon(Icons.close))])),
    Expanded(child: Row(children: [
      SizedBox(width: 160, child: ListView(children: ['General','Battery','Bandwidth','Display','Behavior','Alerts','Advanced','About']
        .map((p) => ListTile(dense: true, selected: page == p, selectedTileColor: const Color(0xff0756aa),
          title: Text(p), onTap: () => setState(() => page = p))).toList())),
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: page == 'General' ? _general() : _other()))
    ])),
    Padding(padding: const EdgeInsets.all(12), child: Row(children: [
      OutlinedButton(onPressed: () { setState(() { opacity = 1; thickness = 12; glow = .7; mode = 'both'; speedDisplay = 'both'; displayUnit = 'Auto'; refreshSeconds = .5; maxInput = 2; maxUnit = 'MB/s'; maxController.text = '2'; _updateMax(); }); _startNetwork(); _save(); }, child: const Text('Restore Defaults')),
      const Spacer(), ElevatedButton(onPressed: _save, child: const Text('Apply')), const SizedBox(width: 8),
      FilledButton(onPressed: _closeSettings, child: const Text('OK')), const SizedBox(width: 8),
      OutlinedButton(onPressed: _closeSettings, child: const Text('Close')),
    ]))
  ]));

  @override Widget build(BuildContext context) => Material(
    color: settings ? const Color(0xff050f20) : Colors.transparent,
    child: settings ? _settingsView() : _floatView());
}
