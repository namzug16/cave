// CaveKit: the in-app half of Plato's Cave (`cave`). Drop this file into your
// macOS app target unchanged, then call `CaveHost.runIfRequested(caveFixtures)`
// first thing in your `App.init()`. Normal launches are untouched: render mode
// only starts when `cave` launches the app with `--cave-socket <path>`.

import AppKit
import SwiftUI

@MainActor public final class CaveRegistry {
    var fixtures: [String: () -> AnyView] = [:]

    public func add<V: View>(_ name: String, _ make: @escaping () -> V) {
        fixtures[name] = { AnyView(make()) }
    }
}

@MainActor public enum CaveHost {
    static let registry = CaveRegistry()

    /// Never returns in render mode: it runs the app as a hidden render host.
    public static func runIfRequested(_ registerFixtures: (CaveRegistry) -> Void) {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--cave-socket"), flagIndex + 1 < arguments.count else { return }
        let socketPath = arguments[flagIndex + 1]
        registerFixtures(registry)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            try CaveSocketServer.start(path: socketPath)
        } catch {
            FileHandle.standardError.write(Data("cave host: \(error)\n".utf8))
            exit(1)
        }
        app.run()
        exit(0)
    }

    static func handle(_ request: [String: Any]) -> [String: Any] {
        do {
            switch request["op"] as? String {
            case "ping":
                return ["ok": true, "pid": Int(getpid())]
            case "list":
                return ["ok": true, "fixtures": registry.fixtures.keys.sorted()]
            case "load":
                guard let path = request["path"] as? String else { throw CaveHostError("load needs a path") }
                try loadPatch(path)
                return ["ok": true, "fixtures": registry.fixtures.keys.sorted()]
            case "render":
                return ["ok": true, "renders": try render(request)]
            case "quit":
                DispatchQueue.main.async { exit(0) }
                return ["ok": true]
            case let op:
                throw CaveHostError("unknown op \(op ?? "nil")")
            }
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    static func loadPatch(_ path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw CaveHostError("dlopen: " + String(cString: dlerror()))
        }
        guard let symbol = dlsym(handle, "cave_patch_entry") else { throw CaveHostError("patch has no cave_patch_entry") }
        typealias Entry = @convention(c) (UnsafeMutableRawPointer) -> Void
        registry.fixtures = [:]
        unsafeBitCast(symbol, to: Entry.self)(Unmanaged.passUnretained(registry).toOpaque())
    }

    static func render(_ request: [String: Any]) throws -> [[String: Any]] {
        guard let name = request["fixture"] as? String else { throw CaveHostError("render needs a fixture") }
        guard let make = registry.fixtures[name] else {
            throw CaveHostError("no fixture named \(name); registered: \(registry.fixtures.keys.sorted().joined(separator: ", "))")
        }
        guard let sizes = request["sizes"] as? [[Int]], let appearances = request["appearances"] as? [String],
              let outputDirectory = request["out"] as? String else {
            throw CaveHostError("render needs sizes, appearances and out")
        }
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        var renders: [[String: Any]] = []
        for size in sizes {
            for appearance in appearances {
                let start = Date()
                let path = "\(outputDirectory)/\(size[0])x\(size[1])-\(appearance).png"
                let scale = try renderPNG(make(), width: size[0], height: size[1], dark: appearance == "dark", to: path)
                renders.append(["path": path, "width": size[0], "height": size[1], "appearance": appearance, "scale": scale,
                                "ms": Int(Date().timeIntervalSince(start) * 1000)])
            }
        }
        return renders
    }

    /// Captures the window through the window server, the only path that composites Liquid Glass
    /// and other backdrop effects: `cacheDisplay` and `CARenderer` leave them blank. An app may
    /// capture its own windows without the Screen Recording permission. The window sits on the
    /// sharpest display, below the desktop so nobody sees it: off every display the window server
    /// crops a few pixels and captures at 1x. Returns the pixel scale of the capture (the display's).
    static func renderPNG(_ content: AnyView, width: Int, height: Int, dark: Bool, to path: String) throws -> Int {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let size = NSSize(width: width, height: height)
        let view = NSHostingView(rootView: content
            .frame(width: CGFloat(width), height: CGFloat(height))
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key))
        view.appearance = appearance
        // Otherwise the hosting view resizes the window to its content's fitting size.
        view.sizingOptions = []
        guard let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else {
            throw CaveHostError("no display to render on")
        }
        let window = NSWindow(contentRect: NSRect(origin: screen.frame.origin, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.ignoresMouseEvents = true
        window.appearance = appearance
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        // Lists and forms fill in over a few run loop turns after the first layout.
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        // Only the part of a window over a display is captured, so a window larger than the display
        // is moved under it piece by piece and the pieces are stitched together.
        let scale = Int(screen.backingScaleFactor)
        guard let canvas = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaveHostError("cannot allocate a \(width * scale)x\(height * scale) px canvas")
        }
        let tileWidth = Int(screen.frame.width), tileHeight = Int(screen.frame.height)
        for tileX in stride(from: 0, to: width, by: tileWidth) {
            for tileY in stride(from: 0, to: height, by: tileHeight) {
                window.setFrameOrigin(NSPoint(x: screen.frame.minX - CGFloat(tileX), y: screen.frame.minY - CGFloat(tileY)))
                CATransaction.flush()
                let tile = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                                  width: CGFloat(min(tileWidth, width - tileX)), height: CGFloat(min(tileHeight, height - tileY)))
                // Global display coordinates: origin at the top left of the primary display, y down.
                let captureRect = CGRect(x: tile.minX, y: NSScreen.screens[0].frame.maxY - tile.maxY, width: tile.width, height: tile.height)
                guard let image = captureWindow(window.windowNumber, in: captureRect) else {
                    throw CaveHostError("the window server returned no image for the render window")
                }
                guard image.width == Int(tile.width) * scale, image.height == Int(tile.height) * scale else {
                    throw CaveHostError("captured \(image.width)x\(image.height) px for a \(Int(tile.width))x\(Int(tile.height)) pt piece at \(scale)x")
                }
                canvas.draw(image, in: CGRect(x: tileX * scale, y: tileY * scale, width: image.width, height: image.height))
            }
        }
        guard let image = canvas.makeImage() else { throw CaveHostError("cannot assemble the capture") }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaveHostError("PNG encoding failed")
        }
        try png.write(to: URL(fileURLWithPath: path))
        return scale
    }

    /// `CGWindowListCreateImage`, looked up at run time because the SDK marks it obsolete.
    /// shortcut: relies on a deprecated call; move to ScreenCaptureKit if macOS drops it, which needs the Screen Recording permission.
    static func captureWindow(_ windowNumber: Int, in rect: CGRect) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let includingWindow: UInt32 = 1 << 3
        let bestResolution: UInt32 = 1 << 3
        return unsafeBitCast(symbol, to: CreateImage.self)(rect, includingWindow, UInt32(windowNumber), bestResolution)?.takeRetainedValue()
    }
}

struct CaveHostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One newline-terminated JSON request per connection, answered with one JSON line.
enum CaveSocketServer {
    static func start(path: String) throws {
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CaveHostError("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard listener >= 0, bound == 0, listen(listener, 8) == 0 else {
            throw CaveHostError("cannot listen on \(path): \(String(cString: strerror(errno)))")
        }
        Thread.detachNewThread {
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { continue }
                serve(connection)
            }
        }
    }

    nonisolated static func serve(_ connection: Int32) {
        defer { close(connection) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !data.contains(UInt8(ascii: "\n")) {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(buffer, count: count)
        }
        let requestData = data
        let responseData: Data = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let request = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any]
                let response = request.map(CaveHost.handle) ?? ["ok": false, "error": "request is not a JSON object"]
                return (try? JSONSerialization.data(withJSONObject: response)) ?? Data(#"{"ok":false}"#.utf8)
            }
        }
        let line = responseData + Data("\n".utf8)
        _ = line.withUnsafeBytes { write(connection, $0.baseAddress, line.count) }
    }
}
