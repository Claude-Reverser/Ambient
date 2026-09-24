import AVFoundation
import AppKit
import WebKit

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class VideoView: NSView {
    let video = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(video)
        video.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }
}
@MainActor final class Renderer: NSObject, WKNavigationDelegate {
    let wallpaper: Wallpaper
    let window: DesktopWindow
    let mediaURL: URL
    let profile: QualityProfile
    private let imagePixelLimit: Int
    private(set) var player: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?
    private(set) var web: WKWebView?
    private(set) var gif: GIFPlayer?
    private(set) var scene: MetalScenePlayer?
    private var preparedScene: SceneResources?
    private var sceneTime = 0.0
    private let sceneFPS: Int
    private let displayScale: CGFloat
    private(set) var paused = true
    private var stopped = false
    private var resumeTime = CMTime.zero
    private var imageTask: Task<Void, Never>?
    private var onError: ((String) -> Void)?
    private var observation: NSKeyValueObservation?
    private var healthTimer: Timer?
    private var health = VideoHealth()
    private var onEvent: ((String) -> Void)?
    private var visible = true
    private var occlusionObserver: NSObjectProtocol?
    var hasLiveResources: Bool {
        player != nil || web != nil || gif != nil || scene != nil || preparedScene != nil
            || window.contentView != nil
    }
    init(
        wallpaper: Wallpaper, screen: NSScreen, mediaURL: URL? = nil,
        profile: QualityProfile = .balanced, initiallyPaused: Bool = false,
        sceneResources: SceneResources? = nil, sceneFPS: Int = 30,
        onEvent: ((String) -> Void)? = nil, onError: @escaping (String) -> Void
    ) {
        self.preparedScene = sceneResources
        self.sceneFPS = sceneFPS
        self.displayScale = screen.backingScaleFactor
        self.wallpaper = wallpaper
        self.mediaURL = mediaURL ?? wallpaper.url
        self.profile = profile
        self.onError = onError
        self.onEvent = onEvent
        imagePixelLimit = min(
            profile.maxDimension,
            Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor))
        window = DesktopWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.contentView = nil
        window.setFrame(screen.frame, display: true)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.occlusionChanged() } }
        if !initiallyPaused { setPaused(false) }
    }
    private func load() {
        // The window was ordered out while paused. Assume it is visible again; the occlusion
        // notification corrects this once the window server has placed it.
        visible = true
        switch wallpaper.kind {
        case .video:
            let view = VideoView(frame: NSRect(origin: .zero, size: window.frame.size))
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            let item = AVPlayerItem(url: mediaURL)
            item.preferredForwardBufferDuration = 1
            let looper = AVPlayerLooper(player: player, templateItem: item)
            self.looper = looper
            observation = looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                if looper.status == .failed { Task { @MainActor in self?.checkVideoHealth() } }
            }
            self.player = player
            view.video.player = player
            window.contentView = view
            if resumeTime > .zero {
                player.seek(
                    to: resumeTime, toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600))
            }
            if visible { player.play() }
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkVideoHealth() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            healthTimer = timer
        case .image:
            let view = NSImageView(frame: NSRect(origin: .zero, size: window.frame.size))
            view.imageScaling = .scaleProportionallyUpOrDown
            window.contentView = view
            imageTask = Task { [weak self, weak view] in
                guard let self else { return }
                let image = await ImageLoader.shared.image(wallpaper.url, maxPixel: imagePixelLimit)
                guard !Task.isCancelled, !paused else { return }
                view?.image = image
                if image == nil { onError?("The image could not be decoded.") }
            }
        case .scene:
            if let resources = preparedScene {
                preparedScene = nil
                installScene(resources)
            } else {
                imageTask = Task { [weak self] in
                    guard let url = self?.wallpaper.url else { return }
                    do {
                        let resources = try await SceneLoader.shared.resources(for: url)
                        guard let self, !Task.isCancelled, !paused else { return }
                        installScene(resources)
                    } catch { if !Task.isCancelled { self?.onError?(error.localizedDescription) } }
                }
            }
        case .web:
            if wallpaper.url.pathExtension.lowercased() == "gif" {
                do {
                    let animation = try GIFPlayer(
                        url: wallpaper.url, size: window.frame.size, maxPixel: imagePixelLimit,
                        fps: profile.fps)
                    gif = animation
                    window.contentView = animation.view
                    animation.play()
                    if !visible { animation.setVisible(false) }
                } catch { Task { [weak self] in self?.onError?(error.localizedDescription) } }
            } else {
                loadWeb()
            }
        }
        window.orderBack(nil)
    }
    private func installScene(_ resources: SceneResources) {
        let fps = profile == .original ? sceneFPS : min(sceneFPS, Int(profile.fps))
        let player = MetalScenePlayer(
            resources: resources, size: window.frame.size, scale: displayScale,
            maxDimension: profile.maxDimension, fps: fps, offset: sceneTime
        ) { [weak self] error in self?.onError?(error) }
        scene = player
        window.contentView = player.view
        player.play()
        if !visible { player.setVisible(false) }
    }
    // A wallpaper fully covered by other windows (a full-screen app, a maximized window) is not
    // worth decoding or drawing. Web wallpapers are left alone; WebKit throttles hidden pages.
    private func occlusionChanged() {
        let visible = window.occlusionState.contains(.visible)
        guard visible != self.visible else { return }
        self.visible = visible
        guard !paused, !stopped else { return }
        scene?.setVisible(visible)
        gif?.setVisible(visible)
        if let player {
            health = VideoHealth()
            if visible { player.play() } else { player.pause() }
        }
    }
    private func loadWeb() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(
            frame: NSRect(origin: .zero, size: window.frame.size), configuration: configuration)
        view.navigationDelegate = self
        web = view
        window.contentView = view
        view.loadFileURL(
            wallpaper.url,
            allowingReadAccessTo: URL(fileURLWithPath: wallpaper.root, isDirectory: true))
    }
    func checkVideoHealth() {
        guard !paused, !stopped, visible, let player else { return }
        let failed =
            player.status == .failed || player.currentItem?.status == .failed
            || looper?.status == .failed
        switch health.inspect(
            position: player.currentTime().seconds,
            item: player.currentItem.map(ObjectIdentifier.init), failed: failed)
        {
        case .none: break
        case .resume:
            onEvent?("Video stalled; resuming playback")
            player.playImmediately(atRate: 1)
        case .rebuild:
            onEvent?("Recreating video decoder after a stall")
            releaseResources()
            load()
        case .failed:
            onError?(
                "The video repeatedly failed to recover. Your wallpaper is kept; choose Resume or try another file."
            )
        }
    }
    private func releaseResources() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let time = player?.currentTime(), time.isNumeric { resumeTime = time }
        imageTask?.cancel()
        imageTask = nil
        player?.pause()
        observation = nil
        looper?.disableLooping()
        looper = nil
        (window.contentView as? VideoView)?.video.player = nil
        player?.removeAllItems()
        player = nil
        gif?.stop()
        gif = nil
        if let scene {
            sceneTime = scene.elapsed
            scene.stop()
        }
        scene = nil
        preparedScene = nil
        web?.navigationDelegate = nil
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        window.contentView = nil
        window.orderOut(nil)
    }
    func setPaused(_ value: Bool) {
        guard !stopped else { return }
        if paused == value {
            if value { preparedScene = nil }
            return
        }
        paused = value
        health = VideoHealth()
        if value { releaseResources() } else { load() }
    }
    func stop() {
        stopped = true
        paused = true
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        releaseResources()
        onError = nil
        onEvent = nil
        window.close()
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let allowed =
            url?.isFileURL == true
            && url!.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: wallpaper.root).standardizedFileURL.resolvingSymlinksInPath()
                    .path + "/")
        decisionHandler(
            navigationAction.navigationType != .linkActivated && allowed ? .allow : .cancel)
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) { if (error as NSError).code != NSURLErrorCancelled { onError?(error.localizedDescription) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onError?("The web wallpaper stopped unexpectedly. Apply it again to restart.")
    }
}
