// TahoeHUD.swift — big overlay HUD for volume + brightness
// Works on macOS 12+ (including Tahoe / 26). Uses CoreAudio + IOKit + CGEventTap.

import SwiftUI
import AppKit
import CoreAudio
import IOKit
import IOKit.graphics
import ApplicationServices // for CGEventTap

// MARK: - App entry
@main
struct TahoeHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hud = HUDController.shared
    private var audioWatcher: AudioWatcher?
    private var brightnessWatcher: BrightnessWatcher?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hud.setup()

        // Watchers
        audioWatcher = AudioWatcher { HUDController.shared.show(type: .volume, value: $0) }
        audioWatcher?.start()

        brightnessWatcher = BrightnessWatcher { HUDController.shared.show(type: .brightness, value: $0) }
        brightnessWatcher?.start()

        // Add menubar icon
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }

        if let img = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "TahoeHUD") {
            img.isTemplate = true
            button.image = img
        } else {
            button.title = "HUD"
        }
        button.toolTip = "TahoeHUD is running"

        let menu = NSMenu()
        let testItem = NSMenuItem(title: "Show Test HUD", action: #selector(testHUD), keyEquivalent: "h")
        testItem.target = self
        menu.addItem(testItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit TahoeHUD", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func testHUD() {
        HUDController.shared.show(type: .brightness, value: 0.66)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - HUD
enum HUDType { case volume, brightness }

final class HUDController {
    static let shared = HUDController()
    private var window: NSWindow!
    private var host: NSHostingView<HUDView>!
    private var hideWorkItem: DispatchWorkItem?

    func setup() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let size = CGSize(width: min(840, screen.frame.width * 0.7), height: 320)
        window = NSWindow(contentRect: .zero,
                          styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.setFrame(NSRect(x: 0, y: 0, width: size.width, height: size.height), display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false

        host = NSHostingView(rootView: HUDView(value: 0.0, kind: .volume))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderOut(nil)

        recenterWindow()
    }

    private func recenterWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let frame = window.frame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }

    func show(type: HUDType, value: Float) {
        DispatchQueue.main.async {
            self.host.rootView = HUDView(value: value, kind: type)

            // Explicitly recenter the window on both axes
            self.recenterWindow()

            self.window.alphaValue = 0
            self.window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                self.window.animator().alphaValue = 1
            }

            self.hideWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    self.window.animator().alphaValue = 0
                } completionHandler: { self.window.orderOut(nil) }
            }
            self.hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }
}

struct HUDView: View {
    let value: Float
    let kind: HUDType
    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: kind == .volume ? iconForVolume(value) : "sun.max.fill")
                .font(.system(size: 96))
                .foregroundStyle(.white)
                .shadow(radius: 12)
            ProgressView(value: Double(value))
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 560)
        }
        .padding(48)
        .background(.black.opacity(0.75))
        .cornerRadius(40)
    }
    private func iconForVolume(_ v: Float) -> String {
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - Volume watcher
final class AudioWatcher {
    private var device: AudioDeviceID = kAudioObjectUnknown
    private let onVolume: (Float) -> Void
    init(onVolume: @escaping (Float) -> Void) { self.onVolume = onVolume }

    func start() {
        attach()
        if let v = currentVolume() { onVolume(v) }
    }

    private func attach() {
        device = defaultDevice()
        guard device != kAudioObjectUnknown else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMaster)
        AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main) { [weak self] _, _ in
            if let v = self?.currentVolume() { self?.onVolume(v) }
        }
    }

    private func defaultDevice() -> AudioDeviceID {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout.size(ofValue: dev))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMaster)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    private func currentVolume() -> Float? {
        guard device != kAudioObjectUnknown else { return nil }
        var vol = Float32(0)
        var size = UInt32(MemoryLayout.size(ofValue: vol))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMaster)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr {
            return max(0, min(1, vol))
        }
        return nil
    }
}

// MARK: - Brightness watcher (event tap + IOKit polling)
final class BrightnessWatcher {
    private var estimate: Float = 0.5
    private var last: Float = -1
    private let onBrightness: (Float) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?

    init(onBrightness: @escaping (Float) -> Void) { self.onBrightness = onBrightness }

    func start() {
        startTap()
        startPolling()
    }

    private func emit(_ v: Float, force: Bool = false) {
        let c = max(0, min(1, v))
        if force || abs(c - last) > 0.01 {
            last = c
            onBrightness(c)
        }
    }

    private func startTap() {
        let mask = CGEventMask(1 << 14)
        let cb: CGEventTapCallBack = { _, type, cgEvent, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(cgEvent) }
            let watcher = Unmanaged<BrightnessWatcher>.fromOpaque(refcon).takeUnretainedValue()
            if type.rawValue == 14, let ev = NSEvent(cgEvent: cgEvent) {
                watcher.handleNXSystemDefined(ev)
            }
            return Unmanaged.passUnretained(cgEvent)
        }
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                     place: .headInsertEventTap,
                                     options: .listenOnly,
                                     eventsOfInterest: mask,
                                     callback: cb,
                                     userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func startPolling() {
        if let real0 = Self.readBrightnessIOKit() {
            estimate = real0
            emit(real0, force: true)
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let real = Self.readBrightnessIOKit() {
                self.estimate = real
                self.emit(real)
            }
        }
    }

    private func handleNXSystemDefined(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }
        let data = event.data1
        let keyCode = (data >> 16) & 0xFFFF
        let keyFlags = (data >> 8) & 0xFF
        guard keyFlags == 0xA else { return }

        let NX_KEYTYPE_SOUND_UP = 0
        let NX_KEYTYPE_SOUND_DOWN = 1
        let NX_KEYTYPE_BRIGHTNESS_UP = 2
        let NX_KEYTYPE_BRIGHTNESS_DOWN = 3
        let NX_KEYTYPE_MUTE = 7

        switch Int(keyCode) {
        case NX_KEYTYPE_BRIGHTNESS_UP:
            estimate = min(1, estimate + (1.0/16.0))
            emit(estimate, force: true)
        case NX_KEYTYPE_BRIGHTNESS_DOWN:
            estimate = max(0, estimate - (1.0/16.0))
            emit(estimate, force: true)
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE:
            break
        default:
            break
        }
    }

    static func readBrightnessIOKit() -> Float? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IODisplayConnect"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            var brightness: Float = 0
            let kr = IODisplayGetFloatParameter(service, 0,
                                                kIODisplayBrightnessKey as CFString,
                                                &brightness)
            IOObjectRelease(service)
            if kr == KERN_SUCCESS { return max(0, min(1, brightness)) }
            service = IOIteratorNext(iterator)
        }
        return nil
    }
}
