# SpaceRun

A small macOS launcher. Hold **Space**, press a key, and an app or web link opens. Links open in your **system default browser**.

- Hold Space and press **?** to see all your shortcuts.
- Run `spacerun edit` to change them in a window, or edit the JSON / use the CLI.
- Runs as a background service that starts at login. No Dock icon or menu bar icon.

Native Swift, system frameworks only: no third-party dependencies, accounts, licensing, usage counters, telemetry, updater, or network requests of its own (browser shortcuts open websites, as intended). Idle, it uses 0% CPU and about 16 MB of memory (SpaceLauncher measured about 47 MB on the same machine).

## Setup

Requires macOS 13+ and Swift 5.9+ (Xcode or its command-line tools). No administrator access is needed.

1. **Quit SpaceLauncher** (or any other Space-key launcher) so the two do not fight over Space.
2. Build, install, and start:

   ```sh
   swift build -c release
   .build/release/spacerun install
   ~/.local/bin/spacerun start
   ```

3. **Grant Accessibility access.** On first start, macOS asks for it. Enable `spacerun` in System Settings → Privacy & Security → Accessibility. Within a second SpaceRun restarts itself (macOS only applies the permission to a freshly started process) and starts working; you do not need to relaunch it.
   - If `spacerun` is not in the list, click **+**, press **Cmd-Shift-G**, and enter `~/.local/bin/spacerun`.
   - If it still does not work, also enable it under **Input Monitoring**.
   - `spacerun permissions` opens the settings page again at any time.
4. Optional: add `~/.local/bin` to your shell's `PATH` so you can type just `spacerun`.

`install` copies the binary to `~/.local/bin/spacerun`, signs it locally, creates a default config if you do not have one, and registers it to start at login. `start` tells you whether the service is running, waiting for permission, or failed.

**Updating:** pull or edit the code, then repeat step 2. macOS may ask for Accessibility access again after a reinstall, because the binary changed; `start` will wait for it.

## Using it

| Action | What happens |
|---|---|
| Hold Space, press a bound key | Opens the app or link. Keep holding Space to fire more shortcuts. |
| Hold Space, press **?** | Shows the cheat sheet overlay with every shortcut and its icon. Press a key to launch from it; release Space, press Escape, or press ? again to hide it. `/` without Shift works too, unless you have bound `/` yourself. |
| Hold Space, press Escape | Cancels; no space is typed. |
| Tap Space / type normally | Types a space as usual. |

Hold Space for about 200 ms before pressing the key. A quicker key is treated as normal typing.

## Changing shortcuts

### In the editor window

```sh
spacerun edit
```

Each row is one shortcut: pick the key, choose **App** or **URL**, choose the app (Choose… opens a file picker) or type the URL, and pick what happens if the app is already in front:

- **Just open**: bring it to the front (default).
- **Hide**: hide it if it is already in front, otherwise open it.
- **Go back**: return to the previous app if it is already in front (used for iPhone Mirroring).

Below the list you can tune the timing and add apps where Space should be left alone (for example a game or a terminal). Press **Save** or Cmd-S; the running service picks up the change immediately. Duplicate keys are outlined in red and cannot be saved. Closing with unsaved changes asks first.

### From the command line

```sh
spacerun bind e url 'https://outlook.office.com/mail/'
spacerun bind s app '/Applications/Slack.app' --toggle
spacerun bind p app '/System/Applications/iPhone Mirroring.app' --previous
spacerun unbind e
spacerun check            # validate config and that each app exists
```

### In the JSON file

The config lives at `~/.config/spacerun/config.json` (`spacerun config` prints the path). A copy of the default is in [config.example.json](config.example.json).

```json
{
  "activationDelay": 0.2,
  "typingCooldown": 0.2,
  "disabledApps": ["com.apple.Terminal"],
  "bindings": {
    "e": { "kind": "url", "target": "https://outlook.office.com/mail/" },
    "s": { "kind": "app", "target": "/Applications/Slack.app", "behavior": "toggle" }
  }
}
```

- `kind`: `app` (absolute path to a `.app`) or `url` (`http`/`https`).
- `behavior` (apps only, optional): `activate` (default), `toggle`, or `previous`, matching Just open / Hide / Go back above.
- `disabledApps`: bundle IDs where Space is never intercepted.
- Keys are letters, digits, and `` ` - = [ ] \ ; ' , . / `` by physical US/ANSI position, so they do not change with input language or Caps Lock.

Every save reloads automatically, including editors that save by replacing the file. If the file is invalid, the last valid configuration stays active and the error is written to the log.

## Typing behavior

- `activationDelay` (default 0.2 s): how long Space must be held before a shortcut key counts.
- `typingCooldown` (default 0.2 s): if you typed within this time, Space behaves completely normally, so fast typing is never affected.
- A tapped Space is typed when you release it. Holding Space with no shortcut types one space; it does not auto-repeat.
- An early or unbound key types the space first and then the key, so typing order is preserved.
- Command/Control/Option/Shift/Fn + Space passes straight through. Pressing Command/Control/Option/Fn or clicking the mouse while holding Space also releases the held space (so Space-drag gestures work). Shift on its own does not, which is what makes Space + ? possible; Shift + a letter still types the space first.
- After a shortcut, Space and the shortcut key (including its repeat and release) are swallowed.
- macOS secure input (for example password fields) can stop interception; Space then just types normally.

Because a held Space might become a shortcut, the space appears when you release it or press the next key. If that feels slow, lower the delays.

## Managing the service

```sh
spacerun start       # start or restart, and report whether it is running
spacerun stop        # stop for now; it still starts at next login
spacerun status      # show state, PID, and last exit code
spacerun run         # run in the foreground instead (stop the service first); Ctrl-C to stop
spacerun uninstall   # stop and remove the binary and login item; keeps config and log
spacerun --help
```

| File | Purpose |
|---|---|
| `~/.local/bin/spacerun` | Installed binary |
| `~/.config/spacerun/config.json` | Your shortcuts and settings |
| `~/Library/LaunchAgents/local.spacerun.plist` | Login startup definition |
| `~/Library/Logs/SpaceRun.log` | Startup messages and errors; keystrokes and usage are never logged |

A lock file next to the config prevents two copies from running at once. To test with a separate config, set `SPACERUN_CONFIG=/absolute/path/config.json`; an install made with this variable keeps using that path.

## Troubleshooting

- **Nothing happens when I hold Space:** run `spacerun status` and check the log. Make sure Accessibility (and if needed Input Monitoring) is enabled for `~/.local/bin/spacerun`, and that SpaceLauncher is not running.
- **Stopped working after reinstalling:** macOS treats the rebuilt binary as new. Run `spacerun start` and re-enable it in Accessibility (remove the old entry with − first if it is stale).
- **"Already running":** another copy is using the same config; `spacerun stop` or quit the foreground `spacerun run`.
- **An app shortcut does nothing:** `spacerun check` lists any app paths that no longer exist.

## Development

```sh
swift test
swift build -c release
```

The tests cover normal Space, fast typing, activation delay, unknown keys, modified shortcuts, the cheat sheet key, mouse/modifier passthrough, key release/repeat suppression, disabled apps, cancellation, config validation, and the editor's change tracking and save checks. Keyboard interception, the overlay, focus changes, default-browser opening, and login startup need a manual check with permissions granted.

Source layout (`Sources/SpaceRun`):

- `LeaderState.swift`: the Space-key state machine (pure logic, unit tested).
- `Daemon.swift`: event tap, app launching, config reload, permission wait.
- `Overlay.swift`: the Space + ? cheat sheet.
- `Editor.swift`: the `spacerun edit` window.
- `Configuration.swift`: config model, defaults, validation, and key map.
- `Service.swift`: install/start/stop via launchd.
- `main.swift`: command-line commands.
