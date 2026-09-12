# Broschy design

Apple-inspired native macOS direction, requested after the first working version.

The user works at a MacBook and glances at the top edge while a command runs elsewhere. The expanded and compact panel share one Liquid Glass surface that follows the macOS appearance, with rounded SF digits. Only the physical camera region stays black, with the same overlay in both sizes. The main material reflects surrounding content; text, accents and control fills adapt to keep both appearances readable.

- Native macOS app, SwiftUI content with AppKit window behavior.
- Restrained color use: black camera region, regular Liquid Glass panel, translucent interior controls, amber progress, green success and red failure states. Both compact and expanded accents use darker colors in Light and brighter colors in Dark. Compact title, artist, progress, time and playback bars use adaptive tokens.
- System SF type, rounded SF with monospaced digits for time, sentence case English labels.
- A compact indicator flanks the camera. Expanded content appears below it. A single tab row provides Focus, Music, Signals and Later.
- No activation for passive hovering. Editing and the keyboard shortcut deliberately allow focus. Escape closes.
- One native regular Liquid Glass effect on the full visible panel in macOS 26. Interior controls use thin fills and borders instead of stacking glass. Pre-26 uses one AppKit popover backdrop. The app and backdrop inherit the system appearance; no forced color scheme is applied. Native dynamic color tokens and SwiftUI colorScheme update text, fills and borders live. Reduced transparency uses an opaque surface matching the appearance.
- Opening: 360 ms with cubic deceleration (0.16, 1, 0.3, 1). Closing: 260 ms. The visible surface morphs inside a temporarily enlarged top-aligned native window; the transparent canvas disappears at the end of closing.
- Selection: shared geometry moves the tab and duration indicators over 260 ms. Digits transition over 240 ms. Button hover/press feedback takes 140 ms, with only small scales.
- System Reduce Motion and Reduce Transparency preferences update live. App-only QA flags exercise the same policy without changing macOS settings. Playback bars animate only to indicate active music and stop when paused, hidden, or Reduce Motion is enabled.
- Music uses the same adaptive panel, a 64-point album cover, readable track text, centered transport controls and native seek/volume sliders. The first connection explains the macOS consent request. Playback controls appear only after a successful connection. Compact music status yields to active focus and recent job events.
- Compact music uses symmetric wings around the measured camera gap: artwork, elapsed time and a small playback indicator on the left, title and artist on the right. The width is capped by the 480-point expanded panel. Paused tracks stay visible at the same width. Clicking opens Music. Long text truncates with a full tooltip; track changes crossfade over 240 ms. Only the 19-by-17-point indicator redraws at up to 24 Hz; it does not sample audio.

Light palette in OKLCH, converted to sRGB at the renderer boundary:

```css
--background: oklch(0 0 0);
--surface: oklch(0.94 0 0);
--text: semantic primary;
--muted: oklch(0.46 0 0);
--primary: oklch(0.53 0.11 80);
--success: oklch(0.46 0.12 155);
--failure: oklch(0.52 0.16 25);
```

Dark appearance overrides:

```css
--surface: oklch(0.23 0 0);
--raised: oklch(0.29 0 0);
--text: semantic primary;
--muted: oklch(0.86 0 0);
--primary: oklch(0.83 0.125 80);
--success: oklch(0.82 0.15 155);
--failure: oklch(0.78 0.14 25);
```
