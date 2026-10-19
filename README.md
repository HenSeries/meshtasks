# MeshTasks

Todoist-style task manager for a work team with **no server**. Every device
(Android, Linux, Windows, macOS, iOS) keeps a full copy of the team's data and
syncs directly with the other devices.

## Features

- Inbox, Today (with overdue), Upcoming (21 days), Completed, Search
- Projects with sections, list or **board (kanban)** view, favorites, archive, colors
- Sub-tasks, comments, labels, priorities P1–P4, assignees, due date + time
- Recurring tasks (`every day`, `every weekday`, `every 2 weeks`, `every mon, thu`,
  `cada lunes`…). Completing one moves it to the next date.
- Quick add with live preview, in English or Spanish:
  `Send invoice tomorrow 5pm p1 #Finance /Billing @email +Ana every month`
  (`#project` `/section` `@label` `+person` `p1-4`, dates like `hoy`, `mañana`,
  `next week`, `fri`, `20/10`, `oct 20`, `in 3 days`, `a las 9`)
- Swipe right to complete (with undo), swipe left to reschedule, drag to reorder
- **Voice dictation in Spanish and English.** Tap the mic in quick add, or
  hold the + button. Speak naturally: *"Llamar a Ana mañana a las tres de la
  tarde, prioridad uno, proyecto Ventas"* becomes
  `Llamar a Ana mañana a las 15:00 p1 #Ventas`. You review the result before
  it's saved.
- **Private tasks** (lock icon, `!private` / `!privada`, or say "tarea
  privada"). Only your own devices can read them; see below.

## Voice engines

| Platform | Engine | Notes |
|---|---|---|
| Android | System speech service (Google) | Download the Spanish/English offline packs in Android settings to keep audio on the phone |
| iOS / macOS | Apple Speech | |
| Windows | Windows speech recognition | Install the Spanish speech language pack in Windows settings |
| Linux | [whisper.cpp](https://github.com/ggml-org/whisper.cpp), fully offline | Needs `whisper-cli` on PATH and a multilingual model (`ggml-small.bin` recommended, `ggml-base.bin` is faster) in `~/.local/share/meshtasks/whisper/`, or set `MESHTASKS_WHISPER_MODEL` |

## Private tasks

A private task (with its sub-tasks and comments) is encrypted field by field
with your **personal key** (AES-256-GCM). The key is created on your first
device and never leaves your devices unless you copy it.

- The encrypted task still syncs through the whole mesh, so your phone and
  laptop stay in sync even through a teammate's device or the relay.
  Teammates' devices only ever hold ciphertext and don't show the task.
- To see your private tasks on another of your devices, go to
  *Team & devices → Private tasks → Copy key for my other device* and paste it
  there with *Use key from another device*. That also links the device to
  your existing member.
- If you lose every device that has your key, your private tasks can't be
  recovered.
- What teammates can still see: that a record owned by you exists and when it
  changed, but not its contents.

## How the mesh works

- **Storage:** SQLite on each device. Each field of each record is a separate
  CRDT cell (last writer wins, ordered by a hybrid logical clock). Two people
  editing different fields of the same task offline both keep their changes.
- **Discovery:** devices on the same Wi-Fi find each other through a UDP
  broadcast beacon (port 47801).
- **Sync:** HTTP on port 47800. Each peer pulls and pushes only the changes
  since the last sync, about 0.4 s after an edit and every 20 s otherwise.
  Changes hop from device to device, so A ↔ B ↔ C works even when A never
  sees C.
- **Security:** all sync traffic is encrypted with AES-256-GCM using the team
  key from the invite code. A device without the key gets refused.
- **Other networks:** broadcast doesn't cross networks. Use Tailscale (or any
  VPN) and add one teammate's address under *Team & devices → Add address*.
  Peer exchange finds the rest.

## Getting started

1. On the first device: **Create a team** and enter your name.
2. Open *Team & devices → Copy invite code* and send the code privately.
3. On every other device: **Join a team** and paste the code.

If the same person uses two devices, open *Team & devices* on the second one
and pick your existing member with the switch icon.

## Packages

| Platform | File | Install |
|---|---|---|
| Android | `MeshTasks-android.apk` | open it on the phone (allow "install unknown apps") |
| Windows | `MeshTasks-Setup-<ver>.exe` | run the installer (adds a firewall rule for sync) |
| Windows | `MeshTasks-<ver>-windows-x64-portable.zip` | unzip, run `meshtasks.exe` |
| Debian / Ubuntu / Mint | `meshtasks_<ver>_amd64.deb` | `sudo apt install ./meshtasks_<ver>_amd64.deb` |
| Arch | `meshtasks-<ver>-1-x86_64.pkg.tar.zst` | `sudo pacman -U meshtasks-*.pkg.tar.zst` |
| Any Linux | `meshtasks-<ver>-linux-x64.tar.gz` | extract, run `./install.sh` (no root) |

Linux packages need glibc 2.34+ (Ubuntu 22.04+, Debian 12+, Fedora 35+).

- Linux packages: `packaging/build_linux.sh` → `dist/`
- Windows can only be built on Windows: `flutter build windows --release`, then
  `iscc packaging\windows\meshtasks.iss` ([Inno Setup](https://jrsoftware.org/isinfo.php)).
- Or push to GitHub: `.github/workflows/release.yml` builds all of them on
  GitHub's machines. Push a tag like `v0.1.0` to publish a Release with every
  file attached.

## Build

```bash
flutter build apk --release        # Android → build/app/outputs/flutter-apk/app-release.apk
flutter build linux --release      # Linux desktop
flutter build windows --release    # on Windows
flutter build macos --release      # on macOS
flutter build ios --release        # on macOS with Xcode
flutter test                       # engine, sync, parser and UI tests
```

## Optional always-on relay

Phones sleep, so a device that's always on keeps everyone in sync, even when
two teammates are never online at the same time. Any PC, Raspberry Pi or old
phone (Termux) can run the headless node:

```bash
dart run bin/node.dart --db relay.db join "meshtasks1:…" relay
dart run bin/node.dart --db relay.db serve
```

The relay is optional. It's just another peer with no special role.

## Limits worth knowing

- Anyone with the invite code has full read/write access to **team** tasks
  (private tasks stay protected by personal keys). There are no per-person
  permissions on team tasks, and there's no way to revoke an invite yet.
- Android pauses apps in the background. Sync resumes when the app is opened.
  Background sync needs a foreground service (not built yet).
- A device whose clock is more than 5 minutes fast gets rejected until its
  clock is fixed. This protects ordering for everyone.
- Deletes are kept as tombstones so they can sync, so the database only grows.
- Testing tip: `MESHTASKS_DB=/tmp/a.db ./meshtasks` runs several instances
  side by side on one machine.
