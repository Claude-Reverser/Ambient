import AVFoundation
import AppKit
import Darwin
import Foundation

// Opt-in process benchmark, separate from normal widget sampling.
@MainActor enum Benchmark {
    private static var started = false
    private static func argument(_ key: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: key),
            index + 1 < CommandLine.arguments.count
        else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
            usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func runIfRequested(_ library: Library) async {
        guard !started, let path = argument("--benchmark"), let reportPath = argument("--report")
        else { return }
        started = true
        var result: [String: Any] = [
            "scope": "Ambient process only; excludes WindowServer, decoder services and GPU energy",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        do {
            let item = try WallpaperImporter.resolve(URL(fileURLWithPath: path))
            let quality = QualityProfile(rawValue: argument("--quality") ?? "balanced") ?? .balanced
            library.conserve = false
            library.pauseOnBattery = false
            library.allDisplays = false
            library.profile = quality
            result["profile"] = quality.rawValue
            result["input"] = item.url.lastPathComponent
            let prepStart = ProcessInfo.processInfo.systemUptime
            library.apply(item)
            while library.preparing {
                try await Task.sleep(for: .milliseconds(100))
                if ProcessInfo.processInfo.systemUptime - prepStart > 180 {
                    throw ImportFailure.message("Preparation timed out")
                }
            }
            if let error = library.message { throw ImportFailure.message(error) }
            guard let renderer = library.renderers.first else {
                throw ImportFailure.message("No renderer started")
            }
            result["preparationSeconds"] = ProcessInfo.processInfo.systemUptime - prepStart
            if item.kind == .video,
                let track = try await AVURLAsset(url: renderer.mediaURL).loadTracks(
                    withMediaType: .video
                ).first
            {
                let size = try await track.load(.naturalSize)
                result["videoWidth"] = size.width
                result["videoHeight"] = size.height
                result["videoFPS"] = try await track.load(.nominalFrameRate)
            }
            try await Task.sleep(for: .seconds(3))
            let seconds = min(60, max(5, Double(argument("--seconds") ?? "12") ?? 12))
            let sceneStart = renderer.scene?.metrics.snapshot()
            let start = ProcessInfo.processInfo.systemUptime
            let cpu = cpuSeconds()
            var memory: [Double] = []
            var states: [String] = []
            while ProcessInfo.processInfo.systemUptime - start < seconds {
                memory.append(footprintMiB())
                states.append(library.status)
                try await Task.sleep(for: .seconds(1))
            }
            let sampleDuration = ProcessInfo.processInfo.systemUptime - start
            if let scene = library.renderers.first?.scene, let sceneStart {
                let end = scene.metrics.snapshot()
                let frames = end.frames - sceneStart.frames
                result["sceneFrames"] = frames
                result["sceneMeasuredFPS"] = Double(frames) / sampleDuration
                result["sceneGPUAverageMilliseconds"] =
                    frames > 0
                    ? (end.gpuSeconds - sceneStart.gpuSeconds) * 1000 / Double(frames) : 0
                result["sceneTextureMiB"] =
                    Double(scene.resources.allocatedTextureBytes) / 1_048_576
                result["sceneSourceWidth"] = scene.resources.description.width
                result["sceneSourceHeight"] = scene.resources.description.height
                result["sceneDrawableWidth"] = scene.view.drawableSize.width
                result["sceneDrawableHeight"] = scene.view.drawableSize.height
                result["sceneDevice"] = scene.resources.device.name
                result["sceneShader"] =
                    scene.resources.description.animated ? "water-flow" : "static image"
            }
            result["sampleSeconds"] = sampleDuration
            result["sampleStates"] = states
            result["uninterruptedPlayback"] = states.allSatisfy { $0.hasPrefix("Playing") }
            result["cpuPercentOfOneCore"] =
                (cpuSeconds() - cpu) / (ProcessInfo.processInfo.systemUptime - start) * 100
            result["meanFootprintMiB"] = memory.reduce(0, +) / Double(memory.count)
            result["peakFootprintMiB"] = memory.max()
            result["statusAfterSample"] = library.status
            result["activeRendererCount"] = library.renderers.count
            result["rendererReplaced"] = library.renderers.first !== renderer
            result["loopCount"] = library.renderers.first?.looper?.loopCount ?? 0
            result["playerSeconds"] = library.renderers.first?.player?.currentTime().seconds ?? 0
            result["webViewCreated"] = renderer.web != nil
            result["nativeGIFCreated"] = renderer.gif != nil
            result["playbackError"] = library.message ?? "none"
            library.manuallyPaused = true
            try await Task.sleep(for: .seconds(3))
            result["pausedFootprintMiB"] = footprintMiB()
            result["pausedResourcesReleased"] = library.renderers.allSatisfy {
                !$0.hasLiveResources
            }
            library.manuallyPaused = false
            try await Task.sleep(for: .seconds(2))
            result["statusAfterResume"] = library.status
            result["resumedResources"] =
                !library.renderers.isEmpty && library.renderers.allSatisfy { $0.hasLiveResources }
            library.stop()
        } catch {
            result["error"] = error.localizedDescription
            library.stop()
        }
        do {
            try JSONSerialization.data(
                withJSONObject: result, options: [.prettyPrinted, .sortedKeys]
            ).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        } catch { print(error) }
        NSApp.terminate(nil)
    }
}
