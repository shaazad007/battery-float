# Battery Float — Windows 10/11 Flutter app

## Requirements
- Windows 10/11 64-bit
- Flutter SDK (recent stable, Dart >=3.4) installed and added to PATH
- Android Studio with Flutter + Dart plugins
- **Visual Studio 2022 Community or Build Tools** with **Desktop development with C++** workload and Windows 10/11 SDK. Visual Studio Code is NOT a replacement.

## Setup (important)
This ZIP contains the full application Dart source and assets, but not machine-generated Windows runner files. The runner is created locally by Flutter (normal Flutter project workflow).
1. Extract ZIP to e.g. `C:\Projects\battery_float`.
2. Open CMD in the project folder and run `flutter doctor -v`. Fix Windows toolchain errors.
3. Double-click `scripts\setup_windows.bat` (or run `flutter create --platforms=windows --project-name battery_float .` then `flutter pub get`).
4. Open the project root folder in Android Studio (not the `lib` folder).
5. In Android Studio select the **Windows (desktop)** device and run `lib/main.dart`; or CMD: `flutter run -d windows`.
6. For release double-click `scripts\build_release.bat`, or run `flutter build windows --release`.
7. Your executable will be in `build\windows\x64\runner\Release\battery_float.exe`. Distribute the entire Release directory, including DLLs/data.

## Features
- Battery percentage and charging/discharging state, polled every 15 seconds.
- Transparent, draggable, always-on-top widget; compact pill option.
- Windows system tray icon and tooltip (battery % visible when hovering). Windows tray icons cannot reliably show a dynamic numeric percentage without generating/updating icons; this version displays a static battery icon and the % in tooltip.
- Configurable downward-crossing notifications (10-90% presets), sound, opacity.
- Preferences persisted between sessions.
- Closing hides widget to tray; tray Exit quits.

## Notes
- On the first run, a threshold that is already below the current battery percentage does not trigger an alert retroactively; alerts trigger when crossing downwards during monitoring.
- Battery alerts are not guaranteed if Windows suspends the process or the laptop is asleep.
- Windows notification permissions/Focus Assist can suppress toasts. If `local_notifier` fails on a specific Windows build, check the output console.
- Auto-start with Windows is NOT implemented in this version. You may manually place a shortcut to the built EXE in `shell:startup` (Win+R).
- The application needs Windows desktop, not Android emulator.
