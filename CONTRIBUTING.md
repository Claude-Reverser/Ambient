# Contributing

Keep changes small enough to review. Report the trigger, expected behavior, observed behavior, macOS version and Ambient version when filing a bug. Never attach copyrighted wallpaper packages or private logs without reviewing their contents.

## Development

Use Xcode with Swift 6, while keeping the package's Swift 5 language mode. No third-party Swift dependencies are required.

```sh
swift test
./scripts/format.sh
./scripts/format.sh --check
./scripts/build-app.sh
```

Some AppKit/Metal tests require an active graphical session. Local media integration tests are optional:

```sh
AMBIENT_VIDEO_FIXTURE=/absolute/path/video.mp4 swift test
AMBIENT_SCENE_FIXTURE=/absolute/path/scene.pkg swift test
```

Fixtures stay on your computer. Tests must generate their own redistributable data or clearly skip when an optional fixture is absent.

## Code layout

- `Library.swift`: selection, persistence and playback policy.
- `Renderer.swift`, `MetalScene.swift`, `GIFPlayer.swift`: native media lifecycles.
- `PlaybackHealth.swift`: bounded recovery decisions, kept independently testable.
- `DesktopWidgets.swift`: widget windows, edit mode and persistence.
- `WidgetLayout.swift`, `NativeWidgetViews.swift`: drag geometry and native widget presentation.
- `SystemReadings.swift`: shared CPU/RAM/network sampling.
- `CustomWidget.swift`, `WidgetStudio.swift`: offline widget packages and the editor.
- `LibraryView.swift`, `StudioOverview.swift`: library and overview pages.
- `Installer/`, `scripts/`: installer and distribution tooling.

Use descriptive names and normal Swift formatting. Comments should explain constraints, non-obvious behavior or ownership—not narrate the next line. Avoid unrelated rewrites, new polling loops, forced video downscaling, and work on the main thread that can block interaction. Preserve manual Pause and saved preferences.

Test behavioral changes at the boundary where they fail. Drag tests must cover cursor movement and release; persistence-only tests do not prove event handling. Include performance observations when changing rendering or sampling. Never claim a fixed system-resource budget based only on the Ambient process.

Contributions must be yours to license under MIT. Keep third-party attribution and identify borrowed algorithms or code explicitly. Do not add ports of proprietary shaders without resolving their redistribution rights.
