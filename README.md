# Desktop HUD

A per-virtual-desktop context overlay for Windows 11, in a single PowerShell script.

You work across virtual desktops, one per project. Every switch costs you a moment of
"wait, what was I doing here?". Desktop HUD gives each virtual desktop its own note:
a one-line theme plus sectioned task checklists. When you switch desktops, a sleek
panel fades in with that desktop's context. While tasks are pending it stays open;
when there is nothing left to do it shrinks to a single unobtrusive line that still
tells you where you are. Click that line to open it back up.

No install, no dependencies, no Electron: one `.ps1` file running on the PowerShell
and WPF that ship with Windows.

## Features

- **Per-desktop notes**: theme, sections, and task checklists keyed to each virtual
  desktop, using only stable Windows surfaces (registry + documented COM).
- **Signature accent colors**: every desktop gets its own deterministic accent color,
  shown as an edge bar and used across checkboxes and progress, so each desktop is
  recognizable at a glance.
- **No modes, ever**: there is no edit button and no editor window. Every section ends
  in a permanent "+ add task" line: click it, type, press Enter, and the task is saved
  and the caret stays put for the next one. Task text is always editable: click any
  task and type. Same for the theme line and section names.
- **Capture from anywhere**: `Win+Shift+N` shows the panel for the current desktop and
  drops the caret straight into its add line, so a thought becomes a task in one
  keystroke without leaving what you were doing.
- **Tick tasks on the overlay**: real checkboxes; tick to mark done (strikethrough,
  saved instantly), untick to undo. A done/total progress bar tracks the day.
- **Completed tasks, your way**: the eye button (or tray menu) toggles whether done
  tasks stay visible, struck through under each section, or disappear from view.
  "clear completed" sweeps them away when you are ready.
- **Undo for every deletion**: deleting a task, a section, or clearing completed shows
  an Undo strip on the panel for a few seconds. Emptying a task's text deletes it, also
  undoable. Nothing is lost to a stray click.
- **Stays out of your way**: it never takes keyboard focus unless you click into it,
  no Alt-Tab entry, header controls fade in only on hover, and it will not collapse
  while your mouse is over it or you are mid-sentence in a field.
- **Yours to place**: drag it anywhere (position remembered), tune its opacity with
  the hover slider (30 to 100 percent), hide it with the corner ✕.
- **Collapses to a line**: the panel has two forms, and the small line is a first-class
  one, not a separate widget. Collapsed it shows the accent stripe, the desktop name,
  the theme and your progress in about 26 pixels of height; click anywhere on it to
  expand. It collapses in place, so nothing jumps around the screen, and it collapses
  itself once a desktop has nothing pending rather than disappearing on you.
- **Instant autosave**: every change writes to a local `notes.json` next to the
  script. Nothing leaves your machine.
- **Light on resources**: it trims its own working set while idle, settling around
  40 MB, which is less than a minimal compiled WPF app uses untrimmed. No background
  CPU beyond a 400 ms registry read.

## Quick start

Requirements: Windows 11 (Windows 10 with virtual desktops should also work),
Windows PowerShell 5.1 (preinstalled).

```
git clone https://github.com/harshh1802/desktop-hud.git
cd desktop-hud
```

Double-click `DesktopHud.bat`. A blue-dot tray icon appears and the HUD greets you on
your current desktop. To start it automatically at logon:

```powershell
powershell -File DesktopHud.ps1 -Install     # creates a Startup shortcut
powershell -File DesktopHud.ps1 -Uninstall   # removes it
```

## Hotkeys

| Hotkey | Action |
|---|---|
| `Win+Shift+N` | Quick add: show the panel and start typing a task |
| `Win+Shift+H` | Show the panel for the current desktop |
| `Win+Shift+B` | Collapse to the line, or expand again |

Inside the panel: `Enter` commits a task and moves on to the next, `Escape` hands focus
back to the app you were using, `Tab` moves between fields, and hovering a row reveals
its delete button.

The tray icon offers the same actions plus Exit; double-click it to add a task.

## How it works

- Desktop switches are detected by polling
  `HKCU\...\Explorer\VirtualDesktops\CurrentVirtualDesktop` (400 ms), with the
  documented `IVirtualDesktopManager` COM interface as a fallback. Desktop names come
  from the same registry area, so renames in Task View show up automatically. No
  undocumented virtual-desktop APIs are used, which is why this survives Windows
  updates that break desktop "pinning" tools.
- The overlay windows use `WS_EX_TOOLWINDOW`: visible on every virtual desktop and
  absent from Alt-Tab. The panel deliberately does NOT set `WS_EX_NOACTIVATE`, because
  it must be able to take focus when you click into a field; `ShowActivated="False"` is
  what keeps it from stealing focus when it merely appears (verified: showing the panel
  leaves the foreground window untouched).
- UI is WPF with custom control templates (checkboxes, slider, buttons), built and
  driven from PowerShell. The script relaunches itself under Windows PowerShell 5.1
  STA if started from PowerShell 7+.
- State is one JSON file (`notes.json`, gitignored) with per-desktop sections and
  tasks; done tasks are stored with an `x ` prefix, so the file doubles as a plain
  text archive of what you finished.

## Diagnostics

```powershell
powershell -File DesktopHud.ps1 -SelfTest    # environment checks, no UI
powershell -File DesktopHud.ps1 -SmokeTest   # drives the real capture flow, then exits
```

`-SmokeTest` runs against a throwaway notes file in `%TEMP%` (it never touches your
notes) and asserts the whole loop: add a task through the ghost row, confirm the row
clears, rename the task in place, add and name a section, delete it, undo the delete,
then collapse and expand the panel while checking the line renders correctly. It exits
non-zero and prints what broke if any step fails.

A minimal log is written to `hud.log` (gitignored). Single instance is enforced with
a mutex; a second launch exits quietly.

## Contributing

Issues and pull requests are welcome. The whole app is one file, `DesktopHud.ps1`,
organized top to bottom: native interop, desktop primitives, state, XAML + styles,
rendering, collapse/expand, hotkeys, tray, main loop. Please keep new code
dependency-free and on documented Windows surfaces.

## License

[MIT](LICENSE)
