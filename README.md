# Battery Float V3 — Windows Flutter

## Included
- Combined draggable battery + network widget, with green/orange/red battery glow and 100% pulse.
- Download and upload speeds, adjustable manual maximum and speed units, 500 ms default polling.
- Right-click menu and system tray, centered opaque dark settings window.
- Saved opacity, widget position, network preferences, battery alerts.
- Credit: Developed by Mohammad Shaazad.

## Build online (no local Visual Studio required)
1. Extract ZIP; upload **contents** of `battery_float` to GitHub repository root, replacing existing files.
2. Keep `.github/workflows/build-windows.yml` in the repository.
3. GitHub → Actions → Build Windows EXE → Run workflow (or commit to main to trigger).
4. Download the `Battery-Float-Windows` artifact after a successful build.
5. Extract the **whole** Release directory, then launch `battery_float.exe`.

## Notes
- This code has not been compiled on a Windows Flutter toolchain in this environment; check Actions logs and share any failed build step.
- Network speeds measure per-adapter incoming/outgoing byte counters from Windows IP Helper API; this is **not** an internet speed test. Some VPN/virtual adapters may count traffic twice.
- 32-bit counters can wrap on very fast links; samples that reset are clamped to zero.
- `KB/s` and `MB/s` mean bytes per second; `Kbps` and `Mbps` mean bits per second.
- Windows Startup shortcut is not automatically created. Press Win+R, enter `shell:startup`, add a shortcut to the built EXE.
- The Settings window is centered by temporarily resizing/repositioning the main window; closing restores the saved widget location.
