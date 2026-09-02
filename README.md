# Desktop HUD

A per-virtual-desktop context overlay for Windows 11, in a single PowerShell script.

You work across virtual desktops, one per project. Every switch costs you a moment of
"wait, what was I doing here?". Desktop HUD gives each virtual desktop its own note:
a one-line theme plus sectioned task checklists. When you switch desktops, a sleek
panel fades in with that desktop's context. While tasks are pending it stays on
screen; when there is nothing left to do, it quietly fades away.

No install, no dependencies, no Electron: one `.ps1` file running on the PowerShell
and WPF that ship with Windows.

## Features

- **Per-desktop notes**: theme, sections, and task checklists keyed to each virtual
  desktop, using only stable Windows surfaces (registry + documented COM).
- **Signature accent colors**: every desktop gets its own deterministic accent color,
  shown as an edge bar and used across checkboxes and progress, so each desktop is
  recognizable at a glance.
- **Tick tasks on the overlay**: real checkboxes right on the panel; tick to mark done
  (strikethrough, saved instantly), untick to undo. A done/total progress bar tracks
  the day.
- **Completed tasks, your way**: the eye button (or tray menu) toggles whether done
  tasks stay visible, struck through under each section, or disappear from view. A
  "clear completed" action in edit mode sweeps them away when you are ready.
- **Undo for every deletion**: deleting a task, a section, or clearing completed shows
  an Undo strip on the panel for a few seconds. Nothing is lost to a stray click.
- **Inline editing**: click the pencil (or press `Win+Shift+N`) and the panel itself
  becomes the editor: rename the theme and sections, add tasks (Enter), delete tasks,
  add or remove sections. No separate window. The border glows in the desktop's accent
  color while editing, and sections with nothing pending say so ("all done ✓") instead
  of disappearing.
- **Stays out of your way**: never steals keyboard focus (except while you are typing
  in edit mode), no Alt-Tab entry, header controls fade in only on hover, and the
  panel pauses its auto-fade while your mouse is over it.
- **Yours to place**: drag it anywhere (position remembered), tune its opacity with
  the hover slider (30 to 100 percent), hide it with the corner ✕.
- **Optional anchor pill**: a tiny click-through strip at the top of the screen with
  the current desktop's theme, for when you want an always-on anchor.
- **Instant autosave**: every change writes to a local `notes.json` next to the
  script. Nothing leaves your machine.

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
| `Win+Shift+N` | Open the panel in edit mode for the current desktop |
| `Win+Shift+H` | Show the panel for the current desktop |
| `Win+Shift+B` | Toggle the anchor pill |

The tray icon offers the same actions plus Exit; double-click it to edit.

## How it works

- Desktop switches are detected by polling
  `HKCU\...\Explorer\VirtualDesktops\CurrentVirtualDesktop` (400 ms), with the
  documented `IVirtualDesktopManager` COM interface as a fallback. Desktop names come
  from the same registry area, so renames in Task View show up automatically. No
  undocumented virtual-desktop APIs are used, which is why this survives Windows
  updates that break desktop "pinning" tools.
- The overlay windows use `WS_EX_TOOLWINDOW` + `WS_EX_NOACTIVATE`: visible on every
  virtual desktop, absent from Alt-Tab, and unable to steal keyboard focus. The pill
  is additionally click-through (`WS_EX_TRANSPARENT`).
- UI is WPF with custom control templates (checkboxes, slider, buttons), built and
  driven from PowerShell. The script relaunches itself under Windows PowerShell 5.1
  STA if started from PowerShell 7+.
- State is one JSON file (`notes.json`, gitignored) with per-desktop sections and
  tasks; done tasks are stored with an `x ` prefix, so the file doubles as a plain
  text archive of what you finished.

## Diagnostics

```powershell
powershell -File DesktopHud.ps1 -SelfTest    # environment checks, no UI
powershell -File DesktopHud.ps1 -SmokeTest   # 6-second full run, exits by itself
```

A minimal log is written to `hud.log` (gitignored). Single instance is enforced with
a mutex; a second launch exits quietly.

## Contributing

Issues and pull requests are welcome. The whole app is one file, `DesktopHud.ps1`,
organized top to bottom: native interop, desktop primitives, state, XAML + styles,
rendering, edit mode, hotkeys, tray, main loop. Please keep new code dependency-free
and on documented Windows surfaces.

## License

[MIT](LICENSE)
