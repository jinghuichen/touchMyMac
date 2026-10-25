# TouchMyMac

Bring iPad-like touchscreen interaction to macOS.

TouchMyMac makes external touch displays actually useful on a Mac. It translates raw HID touch input into clicks, scrolling, dragging, gesture actions, shortcut triggers, and an on-screen keyboard, so a touchscreen can feel much closer to a first-class macOS input device instead of a passive display.

This fork focuses on day-to-day usability: direct touch interaction, configurable multi-finger gestures, Mission Control access, floating keyboard support, and a cleaner settings and diagnostics experience.

## What It Supports

- Single-finger tap to click
- Single-finger drag scrolling with adjustable speed
- Hold then move to drag
- Two-finger secondary click
- Two-finger pinch magnification
- Three-finger swipe up for Mission Control
- Four-finger swipe up/down to show or hide a floating keyboard
- Four-finger swipe left to trigger a configurable shortcut sequence
- Five-finger hold to keep a key or key chord pressed
- Live diagnostics and gesture debugging tools

## Current Gesture Model

The default interaction is tuned to feel closer to direct touch than a traditional trackpad translation layer.

- Tap to click
- Drag to scroll
- Hold briefly, then move to drag content or selections
- Rest one finger and tap another nearby finger for right click
- Pinch with two fingers to zoom
- Swipe up with three fingers for Mission Control
- Swipe up with four fingers to show the floating keyboard
- Swipe down with four fingers to hide the floating keyboard

The Settings window lets you customize:

- Scroll speed
- Hold duration
- Double-click distance
- Scroll inertia amount and decay
- Error resistance for noisy touch panels
- Five-finger hold shortcut mapping
- Four-finger left swipe shortcut sequence

## Floating Keyboard

The built-in floating keyboard is designed for touchscreen text entry on macOS.

- Full Mac (US ANSI) layout with number row, symbols, and arrow keys
- Keys fire on touch down, and overlapping fingers each type their own key, so fast typing doesn't drop letters
- Sticky shift, control, option, and command for shortcuts like ⌘C, plus caps lock
- Delete, space, and arrow keys repeat while held
- Triggered by four-finger swipe up; hidden by four-finger swipe down or the hide key

## Requirements

- macOS 12 or later
- A USB touchscreen that exposes touch input through HID
- Accessibility permission enabled for TouchMyMac

TouchMyMac should work with many touchscreens that already work on Windows, but hardware quality varies and some panels are noisier than others.

The current version of this fork has been tested on:

- LG Smart Monitor Swing

Other HID-compatible touchscreens may also work, but they are not currently validated by this fork.

## Build

Open the project in Xcode:

```bash
open TouchMyMac.xcodeproj
```

Or build from the command line:

```bash
xcodebuild \
  -project TouchMyMac.xcodeproj \
  -scheme TouchMyMac \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

## Run

1. Build and launch `TouchMyMac.app`.
2. Open Settings and grant Accessibility access.
3. Connect your touchscreen.
4. Assign the target screen if needed.
5. Start interacting directly on the display.

If input is unstable, use the Diagnostics pane to inspect connection state, gesture recognition, and live touch counters.

## Project Structure

- `TouchMyMac/`
  App UI, settings, status item integration, diagnostics, and floating keyboard
- `Core/`
  HID parsing, touch tracking, gesture recognition, and event injection
- `scripts/`
  Small project utilities

## Notes

- TouchMyMac works entirely in user space.
- Accessibility permission is required because the app injects input events into macOS.
- Some gesture behavior is intentionally conservative to reduce accidental activation on noisy panels.

## Acknowledgements

This project builds on the original TouchMyMac and TouchUpCore work by Sebastian Hueber. The current version keeps that foundation and extends it with additional gesture support, customizable shortcut mappings, a floating keyboard, updated settings UI, and ongoing macOS-focused refinements.

## License

See [LICENSE](LICENSE).
