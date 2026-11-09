# SpaceRun

A small macOS launcher. Hold **Space**, press a key, and an app or web link opens. Links open in your **system default browser**.

- Hold Space and press **?** to see all your shortcuts.
- Open SpaceRun to change them in a window, or edit the JSON / use the CLI.
- Runs as a background service that starts at login. No Dock icon; the menu bar icon is optional.

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
   - If SpaceRun is not in the list, click **+** and choose `SpaceRun` in your home folder's **Applications** folder (`~/Applications/SpaceRun.app`).
   - If it still does not work, also enable it under **Input Monitoring**.
   - `spacerun permissions` opens the settings page again at any time.
4. **Make it yours.** SpaceRun starts with a few example shortcuts (Calendar, Finder, Music, Notes, Safari, Terminal, github.com, wikipedia.org). Open the editor to replace them with your own:

   ```sh
   ~/.local/bin/spacerun edit
   ```

   Double-click a shortcut to change it, select the examples you do not want and press Delete, and click **+** to add your own. Changes save as you make them and work straight away. Hold Space and press **?** at any time to see what is bound.
5. Open a new terminal window and you can type just `spacerun`. If `~/.local/bin` was not already on your `PATH`, `install` added one line to `~/.zshrc` (or `~/.bash_profile` for bash); `uninstall` removes it again.

`install` builds a small app, `~/Applications/SpaceRun.app` (with its icon, so it is easy to recognise in Privacy & Security), signs it locally, links `~/.local/bin/spacerun` to it, creates the example config if you do not have one (an existing config is never overwritten), and registers it to start at login. It then prints the next two steps. While you still have only the example shortcuts, `start` reminds you to run `spacerun edit`. `start` tells you whether the service is running, waiting for permission, or failed.

### Several users on one Mac

Steps 1–5 install SpaceRun for your account only. To install it once for every account, with each user keeping their own shortcuts:

```sh
swift build -c release
sudo .build/release/spacerun install --all-users
```

This puts the app in `/Applications/SpaceRun.app`, links `/usr/local/bin/spacerun` to it (already on every user's `PATH`), and adds a login item in `/Library/LaunchAgents`, so SpaceRun starts in every user's login session. Each user has their own config (`~/.config/spacerun/config.json`, created on first start), lock file, and log (`~/Library/Logs/SpaceRun.log`). Each user then runs `/usr/local/bin/spacerun start` (or logs out and back in), followed by `/usr/local/bin/spacerun edit`. Allowing Accessibility needs an administrator password if the user is not an administrator. Remove a per-user install first (`~/.local/bin/spacerun uninstall`), because it takes priority for that user. To remove the all-users install: `sudo /usr/local/bin/spacerun uninstall --all-users`.

**Updating:** pull or edit the code, then repeat step 2. macOS may ask for Accessibility access again after a reinstall, because the app changed; `start` will wait for it.

**Upgrading from an older SpaceRun** (before it was an app): run `install` as above, then remove the old `spacerun` entry from Privacy & Security → Accessibility with **−**. Older versions had no bundle ID, so that entry cannot be removed automatically.

## Using it

| Action | What happens |
|---|---|
| Hold Space, press a bound key | Opens the app or link. Keep holding Space to fire more shortcuts. |
| Hold Space, press **?** | Shows the cheat sheet overlay with every shortcut and its icon. Press a key to launch from it; release Space, press Escape, or press ? again to hide it. `/` without Shift works too, unless you have bound `/` yourself. |
| Hold Space, press Escape | Cancels; no space is typed. |
| Tap Space / type normally | Types a space as usual. |

Hold Space for about 200 ms before pressing the key. A quicker key is treated as normal typing.

## Changing shortcuts

### In the SpaceRun window

Open SpaceRun from Applications, choose **Edit Shortcuts…** from the menu bar icon, or run `spacerun edit`.

Each shortcut is one row: its key, the app or website, and what it does when the app is already in front. Changes save immediately and the service picks them up straight away, like System Settings; there is no Save button.

- **Add:** click **+** (or File → New Shortcut, Cmd-N). Type the key to use with Space, then choose an app or enter a web address (`example.com` is fine). A key that is already used is pointed out before you can add it.
- **Change:** double-click a row, or Control-click and choose **Edit…**.
- **Delete:** select rows and press Delete or click **−**. Edit → Undo (Cmd-Z) brings them back.
- **If already in front** (apps only): **Keep it in front** (default), **Hide it**, or **Go back to previous app** (handy for iPhone Mirroring).

**Settings** (the gear button, the menu bar icon, or Cmd-,) holds the menu bar icon switch, the timing, and apps where Space is left alone (for example a game).

### Menu bar icon

SpaceRun shows a Space-bar icon in the menu bar with **Edit Shortcuts…**, **Settings…**, **Pause Shortcuts**, and **Quit SpaceRun**. Hide it with Settings → **Show SpaceRun in the menu bar**; you can still open SpaceRun from Applications, or with `spacerun edit`. Quitting stops the shortcuts until you next log in or run `spacerun start`; closing the SpaceRun window does not.

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
- `showMenuBarIcon` (optional, default `true`): show the menu bar icon.
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
spacerun uninstall   # stop, remove the app, login item, PATH line, and Privacy & Security entries; keeps config and log
spacerun --help
```

| File | Purpose |
|---|---|
| `~/Applications/SpaceRun.app` | Installed app |
| `~/.local/bin/spacerun` | Command-line link to the app |
| `~/.config/spacerun/config.json` | Your shortcuts and settings |
| `~/Library/LaunchAgents/local.spacerun.plist` | Login startup definition |
| `~/Library/Logs/SpaceRun.log` | Startup messages and errors; keystrokes and usage are never logged |

With `--all-users`, the app is `/Applications/SpaceRun.app`, the command is `/usr/local/bin/spacerun`, and the login item is `/Library/LaunchAgents/local.spacerun.plist`; the config and log stay per user as above.

A lock file next to the config prevents two copies from running at once. To test with a separate config, set `SPACERUN_CONFIG=/absolute/path/config.json`; an install made with this variable keeps using that path. Without it, the installed service always uses the config in the home folder of the user it runs as.

**Uninstalling cleans up after itself.** `uninstall` removes SpaceRun's Accessibility and Input Monitoring entries from Privacy & Security, unregisters the app, and removes the `PATH` line it added. `uninstall --all-users` also removes the Input Monitoring entry of every user with a SpaceRun config. Only your config and log are kept; delete `~/.config/spacerun` and `~/Library/Logs/SpaceRun.log` to remove those too.

## Troubleshooting

- **Nothing happens when I hold Space:** run `spacerun status` and check the log. Make sure Accessibility (and if needed Input Monitoring) is enabled for SpaceRun, and that SpaceLauncher is not running.
- **Stopped working after reinstalling:** macOS treats the rebuilt app as new. Run `spacerun start` and re-enable it in Accessibility (remove the old entry with − first if it is stale).
- **"Already running":** another copy is using the same config; `spacerun stop` or quit the foreground `spacerun run`.
- **An app shortcut does nothing:** `spacerun check` lists any app paths that no longer exist.

## Development

```sh
swift test
swift build -c release
```

The tests cover normal Space, fast typing, activation delay, unknown keys, modified shortcuts, the cheat sheet key, mouse/modifier passthrough, key release/repeat suppression, disabled apps, cancellation, config validation, and the editor's saving, key conflicts, and undo. `SPACERUN_SNAPSHOT_DIR=/some/dir swift test --filter SnapshotTests` renders the windows to PNGs from `/some/dir/config.json` for a visual check. Keyboard interception, the overlay, focus changes, default-browser opening, and login startup need a manual check with permissions granted.

Source layout (`Sources/SpaceRun`):

- `LeaderState.swift`: the Space-key state machine (pure logic, unit tested).
- `Daemon.swift`: event tap, app launching, config reload, permission wait.
- `Overlay.swift`: the Space + ? cheat sheet.
- `Editor.swift`: the SpaceRun window, its add/edit sheet, and Settings.
- `Daemon.swift` also holds the menu bar icon.
- `Configuration.swift`: config model, defaults, validation, and key map.
- `Service.swift`: install/start/stop via launchd.
- `main.swift`: command-line commands.
- `AppIconData.swift`: the app icon, generated from `Assets/icon-source.png` by `swift scripts/make-icon.swift`.
