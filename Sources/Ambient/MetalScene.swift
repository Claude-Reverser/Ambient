import AppKit
import ImageIO
import MetalKit

// Immutable textures/pipeline are shared across displays. The cache holds only a weak reference.
final class SceneResources: @unchecked Sendable {
    let description: SceneDescription
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let textures: [MTLTexture]
    let samplers: [MTLSamplerState]
    let scales: [SIMD2<Float>]
    var allocatedTextureBytes: Int { textures.reduce(0) { $0 + $1.allocatedSize } }
    init(package: ScenePackage, device: MTLDevice) throws {
        description = try SceneDescription(package: package)
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw SceneError.invalid("Metal queue unavailable")
        }
        self.queue = queue
        pipeline = try ScenePipelineCache.shared.pipeline(
            device: device, fragment: description.animated ? "waterFragment" : "imageFragment")
        var loaded: [MTLTexture] = []
        var sampling: [MTLSamplerState] = []
        var ratios: [SIMD2<Float>] = []
        var decodedBudget = 0
        let generateMipmaps = !description.animated
        for path in [description.basePath, description.maskPath, description.phasePath].compactMap({
            $0
        }) {
            try Task.checkCancellation()
            let payload = try SceneTexture(data: package.entry(path))
            decodedBudget += payload.estimatedBytes
            guard decodedBudget <= 128 * 1024 * 1024 else {
                throw SceneError.unsupported("more than 128 MiB of decoded source textures")
            }
            let texture = try autoreleasepool { () throws -> MTLTexture in
                switch payload.payload {
                case .encoded(let bytes):
                    guard
                        let source = CGImageSourceCreateWithData(
                            bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                        image.width == payload.width, image.height == payload.height,
                        image.bitsPerComponent == 8
                    else { throw SceneError.invalid("embedded image dimensions or bit depth") }
                    return try MTKTextureLoader(device: device).newTexture(
                        cgImage: image,
                        options: [
                            .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
                            .generateMipmaps: generateMipmaps,
                            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                        ])
                case .raw(let bytes, let channels):
                    let format: MTLPixelFormat =
                        channels == 4 ? .rgba8Unorm : channels == 2 ? .rg8Unorm : .r8Unorm
                    let settings = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: format, width: payload.width, height: payload.height,
                        mipmapped: false)
                    settings.usage = .shaderRead
                    settings.storageMode = .shared
                    guard let texture = device.makeTexture(descriptor: settings) else {
                        throw SceneError.invalid("texture allocation failed")
                    }
                    bytes.withUnsafeBytes {
                        texture.replace(
                            region: MTLRegionMake2D(0, 0, payload.width, payload.height),
                            mipmapLevel: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: payload.width * channels)
                    }
                    return texture
                }
            }
            texture.label = path
            let sampler = MTLSamplerDescriptor()
            sampler.minFilter = payload.flags & 1 == 1 ? .nearest : .linear
            sampler.magFilter = sampler.minFilter
            // Water Flow reads a single-level layer framebuffer and its authored flow map.
            // Synthesized mips change flow vectors and blur displaced samples.
            sampler.mipFilter =
                description.animated ? .notMipmapped : (payload.flags & 1 == 1 ? .nearest : .linear)
            // The water pass reads the layer framebuffer, which clamps at the image edge. Repeating
            // would pull pixels from the opposite side of the screen into displaced edge samples.
            sampler.sAddressMode =
                payload.flags & 2 == 2 || (description.animated && loaded.isEmpty)
                ? .clampToEdge : .repeat
            sampler.tAddressMode = sampler.sAddressMode
            guard let state = device.makeSamplerState(descriptor: sampler) else {
                throw SceneError.invalid("sampler allocation failed")
            }
            loaded.append(texture)
            sampling.append(state)
            ratios.append(
                SIMD2(
                    Float(payload.imageWidth) / Float(payload.width),
                    Float(payload.imageHeight) / Float(payload.height)))
        }
        textures = loaded
        samplers = sampling
        scales = ratios
    }
    struct Uniforms {
        var crop: SIMD2<Float>
        var baseScale: SIMD2<Float>
        var maskScale: SIMD2<Float>
        var weights: SIMD2<Float>
        var offsets: SIMD4<Float>
        var baseLimit: SIMD2<Float>
        var phaseScale: Float
    }
    // Per-frame values that depend only on time are computed once here, in double precision,
    // instead of per pixel. Float time loses sub-frame precision after long uptimes and made
    // fract(time * speed) step visibly; wrapping the phase on the CPU keeps motion smooth.
    func uniforms(time: Double, size: CGSize) -> Uniforms {
        let displayAspect = Float(size.width / max(1, size.height))
        let sceneAspect = Float(description.width) / Float(description.height)
        let crop =
            displayAspect > sceneAspect
            ? SIMD2<Float>(1, sceneAspect / displayAspect)
            : SIMD2<Float>(displayAspect / sceneAspect, 1)
        let cycle = time * Double(description.speed)
        let cycles = SIMD4<Float>(
            Self.fract(cycle), Self.fract(cycle + 0.5), Self.fract(cycle + 0.25),
            Self.fract(cycle + 0.75))
        let base = textures[0]
        // Keep displaced samples inside the image when its texture is padded.
        let halfTexel = SIMD2<Float>(0.5 / Float(base.width), 0.5 / Float(base.height))
        return Uniforms(
            crop: crop, baseScale: scales[0],
            maskScale: scales.count > 1 ? scales[1] : SIMD2(1, 1),
            weights: SIMD2(2 * abs(cycles.x - 0.5), 2 * abs(cycles.z - 0.5)),
            offsets: (cycles - 0.5) * description.strength * 0.1,
            baseLimit: scales[0] - halfTexel, phaseScale: description.phaseScale)
    }
    static func fract(_ value: Double) -> Float { Float(value - value.rounded(.down)) }
    func encode(_ encoder: MTLRenderCommandEncoder, time: Double, size: CGSize) {
        var uniforms = uniforms(time: time, size: size)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        for index in textures.indices {
            encoder.setFragmentTexture(textures[index], index: index)
            encoder.setFragmentSamplerState(samplers[index], index: index)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
    // Equivalent math to the verified waterflow shader. No imported shader text is executed.
    // Colors use half precision (8-bit sources); flow vectors stay in float so the 0.498 rest
    // value is exact. Pixels without flow skip the four displaced reads: the final mix would
    // return the original color there anyway (difference below one 8-bit step).
    static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        struct Uniforms { float2 crop; float2 baseScale; float2 maskScale; float2 weights; float4 offsets; float2 baseLimit; float phaseScale; };
        vertex Vertex sceneVertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return { float4(p * 2.0 - 1.0, 0.0, 1.0), float2(p.x, 1.0 - p.y) };
        }
        static inline half4 baseSample(texture2d<half> image, sampler s, float2 uv, constant Uniforms &u) {
            return image.sample(s, min(uv * u.baseScale, u.baseLimit));
        }
        fragment half4 imageFragment(Vertex v [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<half> image [[texture(0)]], sampler imageSampler [[sampler(0)]]) {
            float2 uv = (v.uv - 0.5) * u.crop + 0.5;
            return baseSample(image, imageSampler, uv, u);
        }
        fragment half4 waterFragment(Vertex v [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<half> image [[texture(0)]], texture2d<float> mask [[texture(1)]], texture2d<half> phase [[texture(2)]], sampler imageSampler [[sampler(0)]], sampler maskSampler [[sampler(1)]], sampler phaseSampler [[sampler(2)]]) {
            float2 uv = (v.uv - 0.5) * u.crop + 0.5;
            half4 original = baseSample(image, imageSampler, uv, u);
            float2 flow = (mask.sample(maskSampler, uv * u.maskScale).rg - float2(0.498)) * 2.0;
            float amount = length(flow);
            if (amount < 0.002) { return original; }
            half noise = phase.sample(phaseSampler, uv * u.phaseScale).r;
            half4 a = mix(baseSample(image, imageSampler, uv + flow * u.offsets.x, u), baseSample(image, imageSampler, uv + flow * u.offsets.y, u), half(u.weights.x));
            half4 b = mix(baseSample(image, imageSampler, uv + flow * u.offsets.z, u), baseSample(image, imageSampler, uv + flow * u.offsets.w, u), half(u.weights.y));
            return mix(original, mix(a, b, smoothstep(half(0.2), half(0.8), noise)), half(amount));
        }
        """
}
// Compiling the Metal source takes tens of milliseconds. Pipelines are immutable, so compile each
// once per device and reuse them across displays, pause/resume and wallpaper changes.
final class ScenePipelineCache: @unchecked Sendable {
    static let shared = ScenePipelineCache()
    private let lock = NSLock()
    private var libraries: [UInt64: MTLLibrary] = [:]
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    func pipeline(device: MTLDevice, fragment: String) throws -> MTLRenderPipelineState {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(device.registryID)|\(fragment)"
        if let pipeline = pipelines[key] { return pipeline }
        let library: MTLLibrary
        if let cached = libraries[device.registryID] {
            library = cached
        } else {
            library = try device.makeLibrary(source: SceneResources.shader, options: nil)
            libraries[device.registryID] = library
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = pipeline
        return pipeline
    }
}
actor SceneLoader {
    static let shared = SceneLoader()
    private weak var cached: SceneResources?
    private var cacheKey = ""
    func resources(for url: URL) throws -> SceneResources {
        try Task.checkCancellation()
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key =
            "\(url.path)|\(info.fileSize ?? 0)|\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if cacheKey == key, let cached { return cached }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SceneError.unsupported("Metal graphics unavailable")
        }
        let resource = try SceneResources(package: ScenePackage(url: url), device: device)
        try Task.checkCancellation()
        cached = resource
        cacheKey = key
        return resource
    }
    func validate(_ url: URL) throws { _ = try SceneDescription(package: ScenePackage(url: url)) }
}
final class SceneMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var gpuSeconds = 0.0
    func completed(_ command: MTLCommandBuffer) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if command.gpuEndTime > command.gpuStartTime {
            gpuSeconds += command.gpuEndTime - command.gpuStartTime
        }
    }
    func snapshot() -> (frames: Int, gpuSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (count, gpuSeconds)
    }
}
@MainActor final class MetalScenePlayer: NSObject, MTKViewDelegate {
    let view: MTKView
    let resources: SceneResources
    let metrics = SceneMetrics()
    private let start = ProcessInfo.processInfo.systemUptime
    private let offset: Double
    private let maxDimension: Int
    private let scale: CGFloat
    private let inFlight = DispatchSemaphore(value: 2)
    private var stopped = false
    private let onError: (String) -> Void
    var elapsed: Double { offset + ProcessInfo.processInfo.systemUptime - start }
    init(
        resources: SceneResources, size: CGSize, scale: CGFloat, maxDimension: Int, fps: Int,
        offset: Double = 0, onError: @escaping (String) -> Void
    ) {
        self.resources = resources
        self.offset = offset
        self.maxDimension = maxDimension
        self.scale = scale
        self.onError = onError
        view = MTKView(frame: NSRect(origin: .zero, size: size), device: resources.device)
        super.init()
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = fps
        view.isPaused = true
        view.enableSetNeedsDisplay = !resources.description.animated
        view.delegate = self
        resize()
    }
    func play() {
        view.isPaused = !resources.description.animated
        view.needsDisplay = true
    }
    // Hidden scenes (for example behind a full-screen app) stop the draw loop; time keeps running.
    func setVisible(_ visible: Bool) {
        guard !stopped, resources.description.animated else { return }
        view.isPaused = !visible
    }
    func stop() {
        stopped = true
        view.isPaused = true
        view.delegate = nil
        view.releaseDrawables()
    }
    private func resize() {
        let pixels = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        let factor = min(1, CGFloat(maxDimension) / max(1, max(pixels.width, pixels.height)))
        view.drawableSize = CGSize(
            width: max(1, (pixels.width * factor).rounded()),
            height: max(1, (pixels.height * factor).rounded()))
    }
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    nonisolated func draw(in view: MTKView) { MainActor.assumeIsolated { drawFrame() } }
    private func drawFrame() {
        guard !stopped, inFlight.wait(timeout: .now()) == .success else { return }
        guard let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable, let command = resources.queue.makeCommandBuffer()
        else {
            inFlight.signal()
            return
        }
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            inFlight.signal()
            return
        }
        resources.encode(encoder, time: elapsed, size: view.drawableSize)
        encoder.endEncoding()
        let semaphore = inFlight
        let metrics = metrics
        command.addCompletedHandler { [weak self] buffer in
            metrics.completed(buffer)
            semaphore.signal()
            if buffer.status == .error {
                Task { @MainActor in self?.onError("The Metal scene renderer reported a GPU error.")
                }
            }
        }
        command.present(drawable)
        command.commit()
    }
}
