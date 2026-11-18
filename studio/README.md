# SPECTRA, Studio edition (v2.0.0-studio)

A developer overlay for a Roblox experience **you own**, ported from SPECTRA Phase 1 v1.27.1.
It uses only standard Roblox APIs and runs as normal scripts in your place, with no executor.

## Install

| File | Studio location | Type |
|---|---|---|
| `ReplicatedStorage/SpectraShared.lua` | `ReplicatedStorage.SpectraShared` | ModuleScript |
| `ServerScriptService/SpectraServer.server.lua` | `ServerScriptService.SpectraServer` | Script |
| `StarterPlayerScripts/SpectraClient.client.lua` | `StarterPlayer.StarterPlayerScripts.SpectraClient` | LocalScript |

To save settings while testing in Studio, turn on Game Settings → Security → *Enable Studio Access to API Services*.
If it's off, settings still work but only last for the session.

## Who can open it

`SpectraServer` sets a `SpectraAuthorized` attribute on each player, and the menu opens only for authorized players. That covers:

- the place creator (user-owned places),
- the group owner (rank 255, group-owned places),
- anyone in `CONFIG.AllowedUserIds`,
- everyone when playing in Studio (`CONFIG.AllowEveryoneInStudio`).

The aim-assist demo also needs `CONFIG.AimAssistDemoEnabled`. The server publishes that switch as `Workspace.SpectraAimAssistDemo`.

## What was kept from v1.27.1

- The theme palette, the 660×445 window, the header with Hide/Unload, the sidebar tabs and the footer status line.
- The toggle, slider, action and row widgets.
- Window dragging and keeping the window on-screen.
- Keybinds: RShift toggles the menu, F8 opens the command center, Home recenters, Ctrl+End unloads.
- The command center: command history (Up/Down), `help`, `settings`, `get`, `set`, `toggle`, `find`, `history`, `diagnose`, `tab`, `clear`, `unload`, and aliases.
- The event log (140 entries) and the **COPY FULL LOG** button.
- The diagnostic report.
- The tracked-connection shutdown that collects errors from every cleanup step.
- The duplicate-instance guard.

## What changed

- **Executor APIs removed:** `getgenv`, `gethui`, `setclipboard`, `loadstring`/`HttpGet` loader, CoreGui parenting. The GUI now goes in `PlayerGui`, and the unload handle is `_G.SPECTRA_UNLOAD`.
- **Config:** settings are validated by the shared schema on both sides and saved per user with `DataStoreService` through a RemoteFunction. The server limits saves to one every 6s.
- **Copy:** Roblox has no clipboard API. COPY FULL LOG and Copy report open a dialog with the text already selected for Ctrl+C, and print it to Output too.
- **Duplicate prevention:** the previous instance is unloaded through `_G.SPECTRA_UNLOAD`, and any leftover `SPECTRA_*` GUIs are destroyed. The server rebuilds its remotes folder when it reloads.
- **Removed from the original:** discovery of Phantom Forces replicated models, enemy-group calibration and the crosshair picker, the snap/lock aimbot with camera writes, the movement modifiers (speed, infinite jump, no fall damage, anti-aim), and the compatibility inspector.

## New gameplay systems

- **Players tab:** a live roster with team, relation, health and distance, from your own `Players`/`Teams`.
- **Team identification:** based on `Player.Team`. Neutral players are never counted as teammates. With no Teams, the game is treated as free-for-all.
- **Visuals:** `Highlight` outlines and name/team/distance tags. Teammates show through walls. Opponents use Occluded depth, so they only show where you can already see them. Roblox renders at most 31 highlights.
- **Aim-assist demo:** friction only. Mouse sensitivity drops while the reticle is over a visible opponent within the radius, and the camera never rotates toward anyone. It doesn't run while the menu is open.

## Not verified

- These scripts have **not been run**. No Luau tooling was available here and Studio wasn't used for this port, so first run may surface errors; F8 and the Output window will show them.
- Whether `UserInputService.MouseDeltaSensitivity` can be written from a LocalScript is untested. If Roblox blocks it, the Assist tab shows `Sensitivity write: BLOCKED` and the demo does nothing. The fallback would be a game-owned camera controller that applies friction itself.
- The copy dialog relies on Ctrl+C, which doesn't exist on touch and console. Those players can only read the text.
