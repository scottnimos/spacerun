# SpaceRun

A small macOS command-line launcher. Hold Space, press a bound key, and open an app or a web link. Links open in your **system default browser**.

Native Swift, system frameworks only. No Dock icon, menu bar icon, GUI, accounts, licensing, usage counters, telemetry, updater, or application-owned network requests. Browser shortcuts intentionally open websites. There are no third-party package dependencies and no idle polling timers.

## Build and install

Requires macOS 13+ and Swift 5.9+ (Xcode or its command-line tools).

```sh
swift build -c release
.build/release/spacerun install
~/.local/bin/spacerun permissions
```

In System Settings → Privacy & Security → Accessibility, enable `spacerun`. If it is missing, click **+**, press **Cmd-Shift-G**, and enter `~/.local/bin/spacerun`. macOS may attribute a foreground invocation to its terminal app; the background service needs the installed executable's access. If event-tap creation still fails, check Input Monitoring too.

Quit SpaceLauncher so both programs do not intercept the same key. Then:

```sh
~/.local/bin/spacerun start
~/.local/bin/spacerun status
```

The service runs independently of your terminal and starts at login. `install` registers its login-startup file and copies/ad-hoc-signs the executable at a stable path; it does not start the service immediately. Rebuilding/reinstalling may require granting Accessibility access again. No administrator access is needed.

Optional: add `~/.local/bin` to your shell's PATH to use just `spacerun`.

## Your bindings

The initial config contains a few example shortcuts. A copy is included in [config.example.json](config.example.json). The live file is:

```text
~/.config/spacerun/config.json
```

For example, this opens Outlook in your default browser:

```json
"e": {
  "kind": "url",
  "target": "https://outlook.office.com/mail/"
}
```

An app binding:

```json
"s": {
  "kind": "app",
  "target": "/Applications/Slack.app",
  "behavior": "toggle"
}
```

`behavior` is optional and defaults to `activate`. `toggle` hides the app when it is frontmost, otherwise launches/focuses it. `previous` switches from the frontmost target app to the previously active app without hiding the target. If no previous app is known yet, it hides the target as a fallback. This is used for iPhone Mirroring.

Edit and save the JSON, or use the CLI:

```sh
spacerun bind e url 'https://outlook.office.com/mail/'
spacerun bind s app '/Applications/Slack.app' --toggle
spacerun bind p app '/System/Applications/iPhone Mirroring.app' --previous
spacerun unbind e
spacerun check
```

Changes reload automatically, including atomic editor saves. Invalid JSON/settings leave the last valid configuration active and write an error to the log. `check` also verifies app paths. `init` and `install` preserve an existing config.

## Typing behavior

- `typingCooldown: 0.2`: Space behaves normally if you have typed within the last 200 ms.
- `activationDelay: 0.2`: hold Space for at least 200 ms before pressing the shortcut key.
- A tapped Space is replayed on release. A hold with no shortcut produces one space; it does not repeat spaces.
- An early or unassigned key replays Space before forwarding the key, preserving typing order.
- Command/Control/Option/Shift/Fn + Space passes through. A modifier or mouse press while awaiting a shortcut also forwards the held Space, allowing Space-drag gestures.
- A recognised shortcut consumes Space and the trigger key, including key repeat and key release. More shortcuts can be used during the same hold. Escape consumes the hold without typing a space.
- Keys use physical US/ANSI positions; Caps Lock does not change the bindings.
- Set `disabledApps` to bundle IDs (e.g. `["com.apple.Terminal"]`) to leave Space alone in those apps. macOS secure input can prevent interception, such as in password fields.

Space presses that may be shortcuts are necessarily delayed until the next key or Space release. Tune the two delays in JSON to suit your typing.

## Manage the process

```sh
spacerun run        # foreground mode; Ctrl-C to stop (stop the service first)
spacerun start      # start/restart background service
spacerun stop       # stop for this login; startup remains enabled next login
spacerun status
spacerun uninstall # stop and remove binary/login startup; keep config and logs
```

The service definition is `~/Library/LaunchAgents/local.spacerun.plist`. Logs are at `~/Library/Logs/SpaceRun.log`; keystrokes and usage history are not logged. There is a per-config lock to prevent duplicate instances. For isolated config testing, set `SPACERUN_CONFIG=/absolute/path/config.json`; an installation made with this variable remembers that config path.

## Verification

```sh
swift test
swift build -c release
```

The tests cover normal Space, fast typing, activation delay, unknown keys, modified shortcuts, mouse/modifier passthrough policy, key release/repeat suppression, disabled apps, cancellation, and config validation. Native keyboard interception, focus changes, default-browser opening, and login startup also require a manual check after granting macOS permissions.
