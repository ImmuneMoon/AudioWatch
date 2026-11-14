# AudioWatch

![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![Platform: Windows 10 | 11](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6)
![Dependencies: none](https://img.shields.io/badge/Dependencies-none-brightgreen)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

A single PowerShell script that watches your Windows audio devices and logs everything that happens to them, with millisecond timestamps. Use it when sound keeps cutting out, switching to the wrong speakers, or changing volume and you want to know **what** did it and **when**.

It only watches. It does not change any devices, volumes or settings, and it sends nothing over the network.

## What it logs

- **Default device changes** for output and input, for each Windows role (Console, Multimedia, Communications)
- **Devices** being added, removed, enabled, disabled or unplugged
- **Apps** opening and closing audio, and which device each one is playing on
- **Volume and mute** changes on the default output, with the app that was in front at the time
- **Context on every default-output change:** the foreground app, processes started in the last 15 seconds, and what is playing where

### Drop-out alerts

When your default output device disappears (disabled, unplugged or no longer present), AudioWatch:

- prints a red `DROP-OUT` line in the console,
- keeps a running count in the window title, for example `Audio watch - 3 drop-outs since 14:02, last 14:37:12`,
- shows a Windows notification (at most one per minute by default, with a count of any it held back).

## Usage

Download `AudioWatch.ps1` and `AudioWatch.bat` into the same folder, then **double-click `AudioWatch.bat`**.

Or run the script from PowerShell yourself:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\AudioWatch.ps1
```

The launcher passes any options on, for example `AudioWatch.bat -TestAlert`.

Leave the window open while you use your PC. Press **Ctrl+C** to stop.

Everything printed to the console is also saved to `audio-watch-<date>-<time>.log` next to the script.

Example output:

```text
2026-11-14 14:37:12.481  DEVICE   output [Speakers (Realtek(R) Audio)] is now NotPresent
14:37:12.481  !!! DROP-OUT #3: default output [Speakers (Realtek(R) Audio)] went NotPresent !!!
2026-11-14 14:37:12.502  DEFAULT OUTPUT (Console) -> [Headphones (USB Audio)]
2026-11-14 14:37:12.530     foreground app   : chrome (pid 9120) "YouTube - Google Chrome"
2026-11-14 14:37:12.531     started <15s ago : (none seen)
2026-11-14 14:37:12.560     playing on [Headphones (USB Audio)] : chrome (9120)
```

### Options

| Parameter | Default | What it does |
| --- | --- | --- |
| `-PollMs` | `1000` | How often (in ms) to check apps, volume and new processes |
| `-ShowPropertyChanges` | off | Also log low-level device property changes (noisy) |
| `-LogPath` | next to the script | Write the log to this file instead |
| `-Seconds` | `0` | Stop after this many seconds (`0` runs until Ctrl+C) |
| `-AlertEverySeconds` | `60` | At most one drop-out notification per this many seconds |
| `-NoAlerts` | off | Turn off Windows notifications (console and title still update) |
| `-TestAlert` | off | Show one test notification and exit |

Run with `-TestAlert` first to check that notifications reach you. If Focus Assist / Do Not Disturb is on, Windows may hide them; the console line and window title still work.

## Notes

- Device events come straight from the Windows Core Audio API, so they are logged the moment Windows reports them. App, volume and process checks run every `-PollMs`, and a missed default-device change is still caught by that poll.
- "Started <15s ago" only lists processes that started while AudioWatch was running.
- No admin rights are needed.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in). Nothing to install.

## ☕ Support the Project

If you find this project helpful and want to support further development by Fulllion Creative Works, consider leaving a tip!

* [Donate via PayPal](https://www.paypal.com/donate/?hosted_button_id=LCDZX75HR4CLC)
* [Support on Ko-fi](https://ko-fi.com/fulllion)

---
© 2026 Fulllion Creative Works. All rights reserved.
