# Windows 11 Explorer on Mac

The user's reference is binding: reproduce Windows 11 File Explorer in Operate mode. Do not invent a new visual identity.

- Mica-like pale neutral tab strip, white active tab, quiet gray command bar, white file surface, fine gray separators.
- Four horizontal bands: 48px tabs, 60px navigation, 56px commands, flexible content; 30px status bar.
- 208px navigation pane; compact 36px rows; recognizable yellow folder shapes, outlined 16–18px command icons, colored navigation glyphs.
- System UI font with Chinese fallbacks, 13px body, 12px metadata, 20px home title. No marketing typography.
- Blue #0067c0 for focused/selected states, pale blue #e5f3ff selection, 4px control radii. Preserve macOS traffic lights.
- Single-clicking the address-bar background or current breadcrumb enters path editing; ancestor breadcrumbs remain navigation links. Menus open beside their trigger and stay inside the viewport. File rows open on double-click and select on single-click.
- File icons scale from 32 to 128 CSS pixels using a status-bar slider, four View presets, and Ctrl+wheel. The grid follows the chosen size; macOS native icons are rendered at sufficient physical resolution for Retina displays.
- Loading, empty directories, search progress, errors, cut state, multi-selection, collision failures, and progress feedback are explicit.
- At smaller desktop sizes, shrink optional columns and hide the details pane before compromising navigation or the filename column.

- View menu order follows the supplied Windows screenshot: four icon presets, list, details, tiles, content, details pane, preview pane, then Show. Keep a separate selection gutter and icon column; Show opens a viewport-clamped submenu with mouse and keyboard support.
- Small icons use horizontal labels; list fills downward into columns; tiles show type/size; content adds date/location. Show settings and mutually exclusive panes persist without resetting navigation or pins.

- More → Appearance offers Light, Dark, and System. Preserve light appearance for existing installs until selected; persist nativeTheme before window creation. Dark uses #191919 file surfaces, #202020 navigation, #242424 menus/toolbars, readable neutral text, and #70c5ff accents. Never invert file icons or change system settings.
