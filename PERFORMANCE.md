# Ambient 0.2 performance checks

These measurements cover the 0.2 rendering core before the 0.3 purple library redesign; they are not a separate benchmark of the new interface.

Measured locally on 11 September 2026: Apple M1, 8 GiB RAM, macOS 26.5.1, one display, release build.

**Default playback preserves the original video.** Lower-quality copies are used only when Eco or Balanced is selected. Native lifecycle and memory improvements also apply in Original mode.

## Short video benchmark

Four-second synthetic moving test pattern, 3840 × 2160, 60 fps, HEVC, generated with FFmpeg's VideoToolbox encoder at a requested 12 Mbit/s. Each mode ran in a fresh app process. Optimized copies were prepared beforehand; each run warmed up for three seconds, then sampled about 12 seconds. Library was empty, with the library window open. Other normal macOS applications remained running.

| Mode | Actual video output | CPU, % of one core | Mean app physical footprint | Peak app footprint |
|---|---|---:|---:|---:|
| Original — default | 3840 × 2160, 60 fps | 7.20% | 40.57 MiB | 45.96 MiB |
| Balanced — optional | 2560 × 1440, 30 fps | 3.87% | 36.51 MiB | 37.41 MiB |
| Eco — optional | 1280 × 720, 24 fps | 2.45% | 35.88 MiB | 37.03 MiB |

All three reported uninterrupted playback, three completed loops, no playback error, released renderer resources during pause, and successful resource recreation on resume. Source resolution and frame rate were preserved in Original mode.

Raw observations: [Original](benchmarks/original.json), [Balanced](benchmarks/balanced.json), [Eco](benchmarks/eco.json).

## What the measurements do and do not mean

- CPU uses `getrusage` process time divided by elapsed wall time. 100% means one logical core, not the entire CPU.
- RAM is `TASK_VM_INFO.phys_footprint` for Ambient only. **It excludes WindowServer, hardware decoder services, WebKit subprocesses, and total GPU/system memory.** These are not whole-system cost measurements.
- GPU utilization, energy consumption, battery life, 4K image fidelity, HDR behavior, and multi-monitor scaling were not benchmarked. No fixed RAM or CPU ceiling is promised for arbitrary wallpapers.
- These are short, single-run observations, not a statistical performance guarantee. Real footage, duration, codec, resolution, frame rate, displays, thumbnails, and other applications change the results.
- Lower-resolution/frame-rate modes intentionally trade image detail and motion smoothness for resource usage. They are optional, never automatically substituted for Original quality.
- A released object graph does not guarantee an immediate fall in process footprint; macOS and media frameworks retain allocator/cache memory. Original's post-pause sample was 43.06 MiB, so the evidence supports releasing playback resources, not a universal immediate RAM reduction.
- The machine reported memory pressure during preliminary runs. Those runs were excluded from the comparison. Each retained report includes all sample states, and every state says Playing. That historical build paused on warning/critical memory pressure. Current releases keep playing on warnings and recover from critical pressure after 20 seconds below critical.

## Regression coverage

Automated tests cover:

- Source-quality default and exact original-file passthrough without a conversion cache.
- Import and project validation, missing media, unsupported containers, path traversal and symlink escape.
- Quality sizing, portrait dimensions, encoder alignment, and no upscaling.
- GIF timeline accuracy when updates skip frames.
- Least-recently-used completed-copy eviction within the disk budget.
- Large-image downsampling before presentation.
- Renderer initialization while paused, resource creation, resource release, resume, and terminal stop behavior in a real AppKit display session.

Video looping and pause/resume were also exercised by the benchmark above. Battery unplug/replug, physical sleep/wake, long-running GIF/web projects, HDR displays and multi-monitor behavior still need broader real-world testing.

## Reproduce

Generate the sample outside the source tree:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=3840x2160:rate=60' -t 4 \
  -c:v hevc_videotoolbox -b:v 12M -tag:v hvc1 -pix_fmt yuv420p -an sample-4k60.mp4
```

Build with `./scripts/build-app.sh`. Run the benchmark command documented in README for each quality mode, using absolute input/report paths. Prepare Eco and Balanced once before measuring fresh-process steady-state playback. Do not run multiple benchmarks concurrently. Reject reports with `uninterruptedPlayback: false`, errors, or no completed loops.

## Ambient 0.4 Waves scene measurement

The local Waves package was measured for 15.68 seconds in Original quality on Apple M1. It retained the 3840 × 2160 source texture and rendered to the display's 2048 × 1280 backing surface at 29.98 fps. Average process CPU was 3.33% of one core; average process footprint was 151.62 MiB, peaking at 154.50 MiB. Pausing released scene resources, with footprint sampled at 73.16 MiB; resume recreated playback successfully.

Average GPU command duration was 1.70 ms per frame, and scene texture allocations were 55.04 MiB. Command duration is not total GPU utilization or power consumption. These are short-run observations with the process-only limitations above. The retained report is `benchmarks/waves-scene.json`. The 24-test suite passed with the optional local Waves fixture enabled; this verifies animated rendering, not visual equivalence to the Windows engine.

## 0.4.4 memory-warning behavior

A real memory warning was observed stopping the user's 1080p video while Ambient remained alive. Warnings now purge thumbnail caches without setting the playback pause condition. Critical pressure still releases playback resources; recovery requires 20 seconds at normal pressure. Repeated normal events no longer restart that recovery timer, and critical events take precedence if flags are coalesced. No resolution or frame-rate reduction is applied. Earlier benchmark descriptions of warning-triggered pauses describe older versions.

## 0.4.5 widget responsiveness

Enabling a widget, entering or leaving edit mode, and changing a size no longer rebuild every widget window. Existing windows, hosting views and custom web views are kept; only widgets that are added or removed are created or closed. Size slider changes save once the value settles. The library window no longer re-renders on widget changes, and the custom HTML editor no longer re-renders while a slider moves. Widget sampling is skipped while every widget is covered and Ambient is not in front. The clock updates as soon as a widget is uncovered. These changes have not been benchmarked yet.
