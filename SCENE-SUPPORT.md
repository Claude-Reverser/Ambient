# Experimental scene support

Ambient now has a native Metal path for a limited subset of Wallpaper Engine `.pkg` scenes. It is not a general Wallpaper Engine runtime.

## Verified wallpaper

**Waves**, Workshop ID **2394043899**, used as a local development fixture:

- Reads `scene.pkg` (`PKGV0014`) in place. No extraction into the project, source changes, or conversion to video.
- Loads the actual **3840 × 2160** image, **1920 × 1080** flow mask, and **32 × 32** phase texture.
- Ports the packaged water-flow shader's phase cycles, offsets, blending, mask amplitude, speed, and phase scale into a built-in Metal shader.
- Uses the scene's configured speed `0.3`, strength `1.0`, and phase scale `2.0`.
- Produces animated GPU output; tests compare independently rendered frames at two times. No 864 × 864 preview substitution is used for playback. The preview JPEG is used only by the library thumbnail.

This is a faithful implementation of the inspected shader math, not a promise of pixel-identical output to the Windows engine. Original-engine reference captures, color/HDR comparisons, and a broader scene corpus have not been tested.

## Supported subset

- PKGV-style archives with a valid bounded file table; tested with PKGV0014.
- TEXV0005 / TEXI0001 textures using TEXB0001–0003 containers.
- Embedded 8-bit PNG/JPEG and raw RGBA8888, RG88, R8 texture data, including bounded LZ4 block decompression.
- One centered, unrotated, untinted image covering an orthographic scene canvas.
- Basic `genericimage`/`genericimage2` material and either no effect or the verified water-flow shader variant.

The water-flow shader signatures are checked against the inspected variant. Unknown imported shader programs are not automatically compiled or guessed at. The app explains unsupported variants and features instead of silently omitting them.

Unsupported: DXT/BC textures, texture video/animation, multiple layers, custom geometry, arbitrary GLSL shaders, other effects, bloom/HDR, camera effects, SceneScript, dynamic properties, particles, puppet animation, audio reactivity, sound layers, and Windows applications. Some otherwise simple projects may be rejected by the deliberately narrow validation rules.

## Resource behavior

- Source images remain full resolution. Original mode renders at the display's backing-pixel size; Eco/Balanced can reduce the render target when explicitly selected.
- Scene motion defaults to **30 fps**, independently of video quality. Choose 24/30/60 fps in the sidebar; original video frame rates are never changed by this control.
- Textures and pipeline are shared across displays. One full-screen triangle and 48 bytes of changing uniforms are submitted per frame.
- At most two command buffers are in flight per display. Busy frames are skipped without blocking the main thread.
- Static scenes draw on demand instead of running a constant animation loop.
- Pause/sleep/memory pressure stops MetalKit drawing, releases drawable surfaces and scene references, and allows the shared textures to be freed once all displays release them. Resume reloads resources and continues the animation time.
- The scene cache is weak: it does not keep GPU textures alive after playback stops.
- Archives are limited to 512 MiB, JSON entries to 2 MiB, texture dimensions to 8192 per side, individual decoded mip payloads to 128 MiB, and total decoded source texture budget to 128 MiB. Generated GPU mipmaps and framebuffers add overhead beyond this input budget.

## Verification

`swift test` exercises synthetic package bounds/path safety, raw and LZ4 texture decoding, unsupported scene rejection, real Metal color/orientation, shared textures, and pause release.

For a locally available full-resolution Waves fixture:

```sh
AMBIENT_SCENE_FIXTURE='/absolute/path/to/scene.pkg' swift test
```

Set `AMBIENT_SCENE_QA` to an existing scratch directory to save GPU frame snapshots at two times. The test skips the personal fixture when the environment variable is absent; copyrighted scene assets are not bundled with Ambient or the tests.

## Implementation references

- [RePKG texture format reader](https://github.com/notscuffed/repkg/tree/master/RePKG.Application/Texture) — format reference, MIT license; see THIRD-PARTY-NOTICES.md.
- [Apple MTKView draw-loop control](https://developer.apple.com/documentation/metalkit/mtkview/ispaused)
- The water-flow behavior was inspected from a local package. The port’s redistribution rights remain unresolved; see THIRD-PARTY-NOTICES.md. No original Wallpaper Engine asset files are bundled.

## 0.4.1 sampling correction

Water Flow now uses a single texture level for its image input and authored vector map. The previous implementation generated mip chains for both embedded PNGs and allowed implicit mip selection during displacement, introducing filtering absent from the single-level effect framebuffer and the Waves flow map. Static image scenes retain generated mipmaps. No new third-party source code was copied.

References inspected: [Wallpaper Engine texture uniforms](https://docs.wallpaperengine.io/en/scene/shader/variables.html), [linux-wallpaperengine framebuffer setup](https://github.com/Almamu/linux-wallpaperengine/blob/master/src/WallpaperEngine/Render/CFBO.cpp), and [texture loading](https://github.com/Almamu/linux-wallpaperengine/blob/master/src/WallpaperEngine/Render/CTexture.cpp). This corrects a verified sampling difference; visual parity with the Windows renderer remains unverified. The 0.4 benchmark predates this correction.
