# Format reference attribution

The PKG/TEX reader was implemented in Swift using RePKG as a file-format reference. No RePKG executable or dependency is shipped. RePKG is available at https://github.com/notscuffed/repkg. Its license is reproduced below.

MIT License

Copyright (c) 2019 notscuffed

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Water-flow shader: unresolved third-party provenance

The `waterFragment` function in `Sources/Ambient/MetalScene.swift` ports the
behavior inspected in a locally supplied Wallpaper Engine water-flow shader.
Permission to redistribute that port has not been independently verified.
The project's MIT license does not grant rights to the underlying third-party
shader. This remains an unresolved licensing item for downstream distributors;
its inclusion is not a representation that all third-party rights are cleared.
No original shader files, wallpaper images, flow maps, workshop packages, or
other downloaded media are bundled with this repository or its DMG.

## Branding

The Ambient logo in `Brand/ambient-logo-v1.png` was generated with an AI image
tool for this project and approved by the project owner. It does not contain
third-party wallpaper artwork.

## Build tools

DMG layout uses the separately installed `ds-store` and `mac-alias` Python
packages. They are build-time tools and are not embedded in the application.
The app links macOS system frameworks; no browser binary or RePKG binary is
bundled.
