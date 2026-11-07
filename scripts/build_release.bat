@echo off
cd /d "%~dp0.."
flutter build windows --release
if errorlevel 1 (pause & exit /b 1)
echo Release is in build\windows\x64\runner\Release\
echo Copy the WHOLE Release folder to another PC, not only the EXE.
pause
