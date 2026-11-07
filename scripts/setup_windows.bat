@echo off
cd /d "%~dp0.."
where flutter >nul 2>nul
if errorlevel 1 (
 echo ERROR: Flutter not found in PATH. Install Flutter SDK and add flutter\bin to PATH.
 pause
 exit /b 1
)
flutter config --enable-windows-desktop
flutter create --platforms=windows --project-name battery_float .
if errorlevel 1 (pause & exit /b 1)
flutter pub get
if errorlevel 1 (pause & exit /b 1)
echo.
echo Setup complete. Open this folder in Android Studio.
echo Run: flutter run -d windows
pause
