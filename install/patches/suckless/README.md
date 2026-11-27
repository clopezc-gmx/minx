# dwm patches (20261127T130129)

This dwm configuration is based on commit `44dbc68` and combines nine patches and personal modifications.

## 1. [Gridmode](https://dwm.suckless.org/patches/historical/gridmode/)

Adds a grid layout that arranges tiled windows in evenly distributed rows and columns.

## 2. [Movestack](https://dwm.suckless.org/patches/movestack/)

Allows moving windows up and down in the client stack, swapping their positions without changing tags.

Keybindings: `Super+Shift+j` and `Super+Shift+k`.

## 3. [Shiftview](https://dwm.suckless.org/patches/shift-tools/)

Allows cycling through tags using circular left and right shifts.

Keybindings: `Super+[` and `Super+]`.

## 4. [Focusonnetactive](https://dwm.suckless.org/patches/focusonnetactive/)

Changes how dwm handles `_NET_ACTIVE_WINDOW` requests. Instead of marking the requesting window as urgent, dwm switches to its tag and focuses it.

## 5. [Statuscolors](https://dwm.suckless.org/patches/statuscolors/)

Adds support for colored status text by interpreting control characters as color scheme selectors.

## 6. [Fancybar](https://dwm.suckless.org/patches/fancybar/)

Displays the titles of all visible windows in the bar instead of showing only the currently selected window.
The selected window receives a distinct color scheme.

## 7. Floating stacking

Changes window stacking behavior depending on the focused window:

- Focusing a tiled window lowers all floating windows.
- Focusing a floating window raises it above other windows.

Custom modification.

## 8. Fullscreen modifications

Customizes fullscreen behavior:

- Removes automatic floating and resizing when entering fullscreen.
- Removes automatic restoration of previous window geometry and state.
- Allows moving and toggling floating on fullscreen windows.
- Removes automatic fullscreen window resizing on screen configuration changes.

Custom modification

## 9. Shorten-title

Displays only the last word of a window title in the internal client name.
For example, `Mozilla Firefox - Example Website` becomes `Website`.
Custom modification.

## Notes

The patches are integrated into a single dwm build.
Some patches modify the same functions, particularly `drawbar()`.
Patch application order matters when separating or updating them.
Custom modifications do not necessarily correspond to standalone upstream patches.

## References

- dwm: [https://dwm.suckless.org/](https://dwm.suckless.org/)
- dwm patches: [https://dwm.suckless.org/patches/](https://dwm.suckless.org/patches/)
