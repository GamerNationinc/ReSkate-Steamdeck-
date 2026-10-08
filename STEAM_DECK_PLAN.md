# ReSkate on Steam Deck: plan

## Goal

A Steam Deck user can play skate. through ReSkate in Game Mode, using only the Deck's controls. That
covers offline play, lobbies, dedicated servers, mods, and the ReSkate menu, console and chat.

## Approach: run the Windows build under Proton, don't port it

Everything ReSkate does in the game happens inside `Skate.exe`, a Windows game. It uses Detours hooks,
reads Frostbite memory and hooks D3D12/DXGI, so `ReSkate.dll` can only ever run where the game runs: in
Proton. A native Linux runtime is not possible. The work is to:

1. make the launcher and runtime run cleanly under Wine/Proton (DXVK and vkd3d-proton);
2. make every feature usable with a gamepad on a 1280x800 screen;
3. package the install and launch setup so a Deck user doesn't need a terminal.

The code already has some Proton handling, so someone has run it there:
- Wine detection, plus an `api-ms-win-core-debug-minidump` shim copied from `dbghelp`
  (`Launcher/launch.cpp:560-594`).
- Finding the Steam account under Proton through `STEAM_COMPAT_CLIENT_INSTALL_PATH` and `loginusers.vdf`
  (`Launcher/launch.cpp:224-285`).
- The native Linux dedicated server, which shows the codebase already builds with GCC.

The Deck work is mostly in launching, input and UI, not in the game hooks. The per-build addresses in
`Engine/Game/Build/20260929/` are tied to `Skate.exe`, not to Windows, so they carry over unchanged.

---

## Phase 0: confirm the baseline on real hardware (no code yet)

Nothing else matters until this is answered. You need a Deck, or a Linux PC running Steam and Proton.

| # | Check | How |
|---|---|---|
| 0.1 | Stock skate. build `25414733` starts under Proton at all (EA app, anti-cheat, Streamline) | Run `Skate.exe` from a folder at the pinned build with `--offline`, using Proton Experimental and then the latest stable Proton |
| 0.2 | The launcher window opens and renders (D3D12 through vkd3d-proton) | Add `ReSkateLauncher.exe` as a non-Steam game with Proton forced |
| 0.3 | Injection works: suspended start, entry-point gate, `LoadLibraryW` checks, remote thread | `logs/ReSkate.log`. Main suspects are in `Engine/Core/Platform/launcher_injection.cpp:448-553` |
| 0.4 | `sl.interposer.dll` loads on an AMD GPU (the runtime refuses to start without it) | `Runtime/runtime_init.cpp:160-183` |
| 0.5 | The overlay appears: the DXGI factory/swapchain hooks land on DXVK/vkd3d's `dxgi.dll` | Look for "Swapchain hook setup incomplete" in the log; `Extension/UI/Overlay/overlay.cpp:242-396` |
| 0.6 | Steam API calls work when started from a non-Steam shortcut (app ID 3354750 from the environment) | Host a lobby; check friends and rich presence |
| 0.7 | Performance at native 800p with FSR and a 30/40/60 cap | Built-in perf overlay plus MangoHud |

Deliverables:
- a short `docs/steam-deck-findings.md` recording the Proton version, what worked, and the logs;
- a list of blockers, which decides how much of Phase 1 is needed.

> If 0.1 fails because of the game itself (for example an anti-cheat or EA app requirement that ReSkate's
> offline mode doesn't already avoid), stop and rethink. Every other phase assumes the game runs under Proton.

---

## Phase 1: launch and injection under Proton

**1.1 Make injection robust on Wine**
- `validated_remote_load_library` requires that `kernel32`/`kernelbase` in the child:
  - is mapped at the same base as in the launcher;
  - has a matching `TimeDateStamp`, `CheckSum` and `SizeOfImage`;
  - has its first 32 bytes of `LoadLibraryW` match the file on disk.

  Wine's builtin DLLs are the likeliest thing to fail these checks. When `wine_get_version` is present,
  keep the base-address and export checks and relax the checksum and disk-bytes comparison. Do not
  remove the checks on Windows.
- Entry-point gate (`launcher_injection.cpp:296-446`): check the `NtSuspendThread` NTSTATUS handling and
  the 30 s `GetThreadContext` polling under Wine, where thread suspension is done with signals.
- Fallback if the remote-thread path can't be made reliable: a **proxy DLL**, i.e. a small
  `version.dll` or `dinput8.dll` placed beside `Skate.exe` that loads `ReSkate.dll`. Wine supports this
  directly with `WINEDLLOVERRIDES="version=n,b"`. It does mean the runtime starts without the launcher's
  gate, so the start-up order would need reworking. Only do this if 1.1 can't be fixed.

**1.2 How the game is started from Steam**
- Two options:
  - **(A)** A non-Steam shortcut to `ReSkateLauncher.exe` with Proton forced.
  - **(B)** Keep the skate. library entry and change its launch options so it runs the launcher instead
    of the game, e.g. `bash -c 'exec "${@/Skate.exe/ReSkateLauncher.exe}"' -- %command% --no-gui`
    (the exact exe name Steam starts must be checked).
- (B) gives the real app ID, the Steam playtime, the cloud prefix and the Deck's "Verified" controller
  settings, so it is the better default. Support both.
- The launcher must be started by Steam so that Proton's `steam.exe` and `STEAM_COMPAT_CLIENT_INSTALL_PATH`
  exist (the Steam detection at `launch.cpp:510-521`).

**1.3 Deck and Proton detection**
- Add one helper, e.g. `platform::running_under_proton()` and `platform::running_on_steam_deck()`, in
  `Engine/Core/Platform/`.
- Signals:
  - `wine_get_version`;
  - the `SteamDeck=1` environment variable (check that Steam still sets it);
  - `ISteamUtils::IsSteamRunningOnSteamDeck` once Steam is loaded.
- Every later Deck-specific default reads this helper. No scattered checks.

**1.4 Smaller Wine fixes**
- **Job object for DepotDownloader** (`Launcher/updater.cpp:523-536`): if `AssignProcessToJobObject` fails
  under Wine, carry on without it instead of aborting.
- **WinHTTP** uses `WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY`; fall back to the default proxy type if that
  errors (`updater.cpp:81-146`, `Engine/Vfs/https_download.cpp`, `Engine/Core/Debug/upload.cpp`).
- **Crash reporting:** Wine's minidumps are limited. Keep the log upload. Tag uploads with the Proton
  version and a Deck flag so Deck crashes can be sorted out.
- **Fonts:** Segoe UI, Arial and Consolas don't exist in the prefix. Embed a monospace font for the console
  (`skate_menu.cpp:288-314` falls back to ImGui's default font today).
- **Startup splash** (`Extension/UI/Startup/startup_window.cpp:509`) is a topmost layered popup. Check it
  doesn't steal focus or presentation under gamescope. If it does, skip it when the helper reports a Deck.

---

## Phase 2: getting the right game build onto the Deck

ReSkate supports one game build (`25414733`). Steam will update the installed game past it.

**Recommended path:** a native setup script run once in Desktop Mode, `contrib/steamdeck/install.sh`. It:
1. downloads the latest ReSkate release zip and checks its SHA-256 against `launcher.json`;
2. installs into `~/Games/ReSkate/` (on the SD card if the user chooses);
3. runs the **native linux-x64 DepotDownloader**, pinned by hash like the Windows one, with the depot and
   manifest from `Engine/Game/Build/supported_build.h`, to fetch exactly the supported build. That avoids
   needing .NET inside Wine;
4. adds a non-Steam shortcut to `ReSkateLauncher.exe`, sets its Proton compatibility tool, and installs
   the controller layout from Phase 3. This is done by editing `shortcuts.vdf` and `config.vdf` while
   Steam is closed, the same way tools like BoilR and Steam ROM Manager do it;
5. prints where profiles, mods and logs live.

**Fallback inside the launcher:** keep the in-launcher download for Windows. Under Proton, try it once
(DepotDownloader needs .NET or a self-contained build in the prefix). If it doesn't work, show a message
pointing to the script instead of failing.

**Self-update:** the launcher's rename-aside update (`updater.cpp:365-443`) should work under Wine. Check
it in Phase 0. The script can also do updates with `install.sh --update`.

**Where data lives:**
- Profiles and game saves are in `%LOCALAPPDATA%\ReSkate` inside the Proton prefix
  (`compatdata/<id>/pfx/...`). Deleting the prefix or the shortcut loses them silently.
- Option 1: when the helper reports Proton, store them beside the launcher, in `<install>/userdata/`.
- Option 2: have the script symlink the prefix folder there.
- Either way, document the location, and consider Steam Cloud only under option (B).

---

## Phase 3: controller-only input (the largest piece of work)

Today the menu (Insert), console (`~`), chat (T or `/`) and park editor all need a keyboard or mouse.

**3.1 Controller combos to open things** (`Extension/UI/Overlay/overlay_input.cpp`)
- Reuse the existing combo system in `Engine/Game/Input/controller_bindings.h`, which already drives
  noclip and push-to-talk.
- Default combos, which can be changed in Settings:
  - menu: hold **View + Menu** (Select + Start) for 0.5 s;
  - chat: **View + D-pad Up**;
  - console: **View + D-pad Down**.
- Read the pad through the existing `DingoSDKOverlayReadControllerInput`. Check the
  `game_window_foreground` gate under gamescope (`cursor.cpp:13-18`).
- Also document binding Insert, `~` and T to Deck back buttons (L4/R4) in Steam Input. That needs no
  code, so it can ship from day one.

**3.2 ImGui gamepad navigation**
- Set `ImGuiConfigFlags_NavEnableGamepad` (`overlay_render.cpp:283`). The Win32 backend already feeds
  XInput into ImGui.
- Check that the game still gets a zeroed pad while the menu is open (`input_capture.cpp:304-326`) so a
  single press doesn't do two things.
- Make the custom widgets navigable:
  - the sidebar uses `InvisibleButton` plus draw lists (`skate_menu.cpp:382-402`);
  - the close "X" (`:421`);
  - sliders, combo boxes and colour pickers.
- Map **B** to back or close, and **LB/RB** to switch tabs.
- Show button hints (A select, B back, LB/RB tabs) in the menu footer when a controller was the last input.

**3.3 On-screen text entry**
- There are 41 `InputText` fields, plus the console, chat and server passwords.
- When a text field becomes active and the last input was a controller, call
  `ISteamUtils::ShowFloatingGamepadTextInput` through the already-loaded `steam_api64.dll`, using the same
  dynamic flat-API pattern as `Extension/Multiplayer/Steam/*`. Then write the result into the field.
- In offline mode the Steam interfaces are stubbed (`Extension/Boot/offline_steam.cpp`), so add a simple
  ImGui on-screen keyboard as a fallback.
- Check whether the game's own `InputField_Widget` in the native menu (`native_menu_rows.cpp`) already
  opens a keyboard.

**3.4 Prefer the native menu on the Deck**
- The "Multiplayer" and "Custom Stuff" tabs in the game's pause menu (`Extension/UI/NativeMenu/`) already
  work with a controller.
- On the Deck, make sure everything needed to play is reachable there: server browser, join by code, host,
  password, voice settings, mods on/off, map and fast travel.
- That way the ImGui menu is a power-user tool, not a requirement.

**3.5 Park editor controller mode** (can ship after the rest)
- Freecam: left stick to move, right stick to look, triggers for up and down, a stick click for fast
  movement.
- Selection: a centre-screen reticle with **A** to pick, instead of mouse picking.
- Gizmo: D-pad or bumpers switch move, rotate and scale; the stick adjusts the active axis, with snapping on.
- Undo and redo: **View + LB/RB**. Save from a menu button.
- Until this ships, provide a Steam Input layout that switches to trackpad-as-mouse while the editor is
  open. ImGui already draws the cursor with `MouseDrawCursor`.

**3.6 Steam Input layout**
- Ship an official Deck layout (`contrib/steamdeck/reskate_controller.vdf`) that the install script
  installs:
  - normal gamepad;
  - L4/R4/L5/R5 bound to menu, console, chat and push-to-talk;
  - right trackpad as mouse;
  - an action set for the park editor.

---

## Phase 4: 800p and the 7" screen

**Menu scale**
- Default `ui scale` to about 1.15 on the Deck (`Engine/Game/UI/menu_scale.h`).
- Make sure the 1000x700 menu fits 1280x800 at that scale: it clamps to display minus 24
  (`skate_menu.cpp:334-337`).

**Sharp fonts**
- Fonts are rasterised once at fixed sizes and stretched with `FontGlobalScale`, which blurs them.
- Rebuild the font atlas at `base size × scale` when the scale changes, and call
  `ImGuiStyle::ScaleAllSizes`.
- This needs the DX12 font-texture re-upload path in the patched `imgui_impl_dx12.cpp`.

**Minimum text size**
- Body text should be at least about 18 px at 800p, since the Deck is held close but the screen is small.
- HUD elements are currently clamped at a minimum scale of 1.0 against 1080p (chat 520 px wide, notices,
  nametags). Check readability and spacing at 800p, and don't let the chat window cover the centre of the
  screen.

**Launcher**
- 1440x840 scales to about 0.89, which fits.
- Add gamepad navigation, or rely on `--no-gui` under option (B) so the launcher window is skipped in Game Mode.
- Move the controls that only exist in the launcher (mods, crash-report toggle) into the in-game menu, or
  make sure they work with the trackpad.

**Test resolutions**
- 1280x800 (the Deck);
- 1920x1080 and 4K over a dock;
- gamescope's FSR at lower internal resolutions.

---

## Phase 5: performance and battery defaults on the Deck

**Main-loop spin**
- `main_sleep` is on by default and uses `TIME_CRITICAL` priority plus a 0.25 ms spin
  (`Extension/Settings/engine_tweaks.cpp:195-240`).
- On a 4-core APU this costs power and can starve other threads. Default it off on the Deck, or shorten
  the spin.
- Check `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` under Wine.

**Worker threads**
- Retune the `job_wake` idle spin (`Extension/Settings/job_spin.h`) for 4 cores and 8 threads.

**A "Deck" graphics preset in the menu**
- FSR at Quality or Balanced, 30 or 40 FPS target, lower GI, the `gi` throttle on, and film grain and
  chromatic aberration off (`Extension/Rendering/local_graphics_controls.cpp`).
- Document gamescope's 40 Hz mode.

**Overlay cost**
- Make sure the profiler sampler, which suspends threads (`Engine/Core/Profiling/sampler.cpp`), stays off.
- Keep the overlay's per-frame cost near zero when nothing is shown. It already skips building frames.

**Multiplayer**
- Check frame times with 16 or more remote skaters on the Deck. The puppet cost model is in
  `Extension/Multiplayer/Remote/puppet_cost.cpp`.
- Consider lower default nametag and player distances on the Deck.

**Memory**
- The mesh-pool sizing in `Runtime/client_tick.cpp:154` reads `DedicatedVideoMemory`, which DXVK reports
  low on the APU. Confirm it keeps the stock 520 MB. Measure total RAM use, since the Deck has 16 GB shared.

---

## Phase 6: packaging, docs and testing

**Release assets**
- Add `ReSkate-SteamDeck-<version>.tar.gz` containing:
  - `install.sh`
  - the controller layout
  - a README
- The script downloads the normal Windows zip, so the binaries stay the same.

**CI**
- `shellcheck` on the scripts.
- A Linux CI job that runs the existing cross-platform tests under GCC (`linux-x64` preset), which already
  build for the server.
- Optional: a Wine smoke test that starts `ReSkateLauncher.exe --no-gui` against a stub executable and
  checks the injection path. That catches Wine regressions without the game.

**Docs**
- A "Steam Deck" section in `README.md`:
  - install steps;
  - the Proton version to use;
  - controls;
  - where data lives;
  - known limits.
- Also update the controls table with the controller combos.

**Test matrix**

| | Offline | Lobby host/join | Dedicated server | Voice | Mods (Thunderstore and manual) | Park editor | Suspend and resume | Dock |
|---|---|---|---|---|---|---|---|---|
| Deck LCD/OLED, Proton Experimental | | | | | | | | |
| Deck, latest stable Proton | | | | | | | | |
| Desktop Linux (non-Deck) | | | | | | | | |

Suspend and resume is specific to the Deck. Check that Steam networking sessions and voice recover, and
that the overlay survives the swapchain being recreated.

**Feedback**
- Add a Proton/Deck field to the crash-report tags and the bug-report template.

---

## Suggested order and rough size

| Milestone | Contents | Size |
|---|---|---|
| **M0: proof** | Phase 0 findings | 1–3 days on hardware |
| **M1: it runs** | Phase 1 (injection relaxed for Wine, detection helper, small Wine fixes) + Steam Input layout with back-button bindings | ~1 week |
| **M2: it installs** | Phase 2 install script + data location + docs | ~1 week |
| **M3: controller-first** | 3.1 combos, 3.2 gamepad navigation, 3.3 floating keyboard, 3.4 native-menu coverage, Phase 4 scale and fonts | 2–3 weeks |
| **M4: polish** | Phase 5 presets and tuning, Phase 6 CI, release asset, test matrix | ~1 week |
| **M5: park editor** | 3.5 controller mode | 1–2 weeks |

Each milestone can be released on its own. After M1 and M2, Deck users can already play, using the back
buttons and the trackpad.

## Open questions

1. Does the pinned skate. build run under Proton at all? (Phase 0.1)
2. Option (A), the non-Steam shortcut, or option (B), replacing the launch command: which is the default?
   (B) is recommended.
3. Should profiles move out of the Proton prefix by default? This changes where Windows-style paths
   resolve, so it needs a migration.
4. Which Proton version to pin and test against?
