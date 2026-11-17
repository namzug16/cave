import Foundation

struct Patch {
    var dylib: String
    var files: [String]
    var staleFiles: [[String: String]]
}

/// Type names a Swift file declares, nested ones included.
public func declaredTypes(in source: String) -> Set<String> {
    let pattern = #/(?m)^\s*(?:(?:@\w+(?:\([^)]*\))?|public|internal|private|fileprivate|package|final|open|indirect|nonisolated)\s+)*(?:struct|class|enum|actor|protocol)\s+(\w+)/#
    return Set(source.matches(of: pattern).map { String($0.output.1) })
}

/// A patch's copy of a type only takes effect where the patch itself constructs it, so an edited
/// view renders anew only if the fixtures, or another patched file that is reached, name it.
/// Returns the edited files none of whose types are reached that way.
/// shortcut: one name-matching pass instead of a declaration graph; upgrade when edits to deeply nested views get common.
public func unreachedFiles(edited: [String: String], fixturesSource: String) -> [String] {
    func identifiers(in source: String) -> Set<String> { Set(source.matches(of: #/\b[A-Za-z_]\w*\b/#).map { String($0.output) }) }
    var reachedNames = identifiers(in: fixturesSource)
    var unreached = Set(edited.keys)
    var progress = true
    while progress {
        progress = false
        for file in unreached.sorted() where !declaredTypes(in: edited[file]!).isDisjoint(with: reachedNames) {
            unreached.remove(file)
            reachedNames.formUnion(identifiers(in: edited[file]!))
            progress = true
        }
    }
    return unreached.sorted()
}

/// Points errors in patch copies back at the user's files. Copies start with an import added to
/// line 1, so only line 1 columns move.
public func mapDiagnostics(_ diagnostics: [Diagnostic], copies: [String: String], prefixLength: Int) -> [Diagnostic] {
    diagnostics.map { diagnostic in
        guard let original = copies[diagnostic.file] else { return diagnostic }
        var mapped = diagnostic
        mapped.file = original
        if mapped.line == 1 { mapped.column = max(1, mapped.column - prefixLength) }
        return mapped
    }
}

extension Workspace {
    /// Compiles the files edited since the last build, plus the fixtures file, into a dylib whose
    /// entry point re-registers every fixture from the edited code.
    func compilePatch(_ state: inout State) throws -> Patch {
        let startedAt = Date()
        let edited = try sourcesChanged(since: state.buildStartedAt, state)
        if let kit = edited.first(where: { $0.hasSuffix("/CaveKit.swift") }) {
            throw CaveError("\(kit) changed since the last build; a patch can't replace the host itself", hint: "run cave reload --full")
        }
        let files = edited.contains(fixturesFile) ? edited : edited + [fixturesFile]
        let module = try state.setting("PRODUCT_MODULE_NAME")
        state.patchCount += 1
        let patchModule = "CavePatch\(state.patchCount)"
        let directory = patches.appendingPathComponent(patchModule)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Copies keep every line where it was, so errors map straight back to the user's file.
        let importPrefix = "@testable import \(module); "
        var copies: [String: String] = [:]
        var editedSources: [String: String] = [:]
        for (index, file) in files.enumerated() {
            let source = try String(contentsOfFile: file, encoding: .utf8)
            if file != fixturesFile { editedSources[file] = source }
            let body = source.replacing(#/(?m)^(\s*)@main\b/#) { $0.output.1 + "     " }
            let copy = directory.appendingPathComponent("\(index)_\((file as NSString).lastPathComponent)").path
            try (importPrefix + body).write(toFile: copy, atomically: true, encoding: .utf8)
            copies[copy] = file
        }
        let entry = directory.appendingPathComponent("cave_entry.swift").path
        try """
            @testable import \(module)
            // The pointer crosses into the main actor as an Int so this compiles under any default isolation.
            @_cdecl("cave_patch_entry")
            nonisolated public func cave_patch_entry(_ registry: UnsafeMutableRawPointer) {
                let address = Int(bitPattern: registry)
                MainActor.assumeIsolated {
                    caveFixtures(Unmanaged<CaveRegistry>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue())
                }
            }
            """.write(toFile: entry, atomically: true, encoding: .utf8)

        let dylib = directory.appendingPathComponent("\(patchModule).dylib").path
        let result = try run(try swiftcArguments(state, module: patchModule, output: dylib) + copies.keys.sorted() + [entry])
        guard result.status == 0 else {
            let diagnostics = mapDiagnostics(parseDiagnostics(result.output), copies: copies, prefixLength: importPrefix.count)
            throw CaveError(diagnostics.isEmpty ? "patch compile failed:\n\(result.output)" : "patch compile failed",
                            hint: "fix the errors and reload; if the code builds in Xcode, the change can't be patched (e.g. it adds stored properties to an unedited type), so run cave reload --full",
                            diagnostics: diagnostics)
        }
        removeOldPatches(keeping: 3)
        state.lastPatch = dylib
        state.lastPatchStartedAt = startedAt
        let fixturesSource = try String(contentsOfFile: fixturesFile, encoding: .utf8)
        let staleFiles = unreachedFiles(edited: editedSources, fixturesSource: fixturesSource).map {
            ["file": $0, "reason": "no fixture or patched view names its types, so renders still use the built code; run cave reload --full"]
        }
        return Patch(dylib: dylib, files: files, staleFiles: staleFiles)
    }

    func swiftcArguments(_ state: State, module: String, output: String) throws -> [String] {
        let productsDirectory = try state.setting("BUILT_PRODUCTS_DIR")
        let swiftVersion = try state.setting("SWIFT_VERSION").split(separator: ".").first.map(String.init) ?? "5"
        var arguments = [
            "xcrun", "swiftc", "-module-name", module, "-emit-library", "-o", output,
            "-target", "\(try state.setting("NATIVE_ARCH_ACTUAL"))-apple-macos\(try state.setting("MACOSX_DEPLOYMENT_TARGET"))",
            "-sdk", try state.setting("SDKROOT"), "-Onone", "-swift-version", swiftVersion,
            "-I", productsDirectory, "-F", productsDirectory,
            // Symbols resolve against the running app when the host loads the patch.
            "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
            "-suppress-warnings", "-module-cache-path", moduleCache.path, "-j", "4",
        ]
        if let isolation = state.buildSettings["SWIFT_DEFAULT_ACTOR_ISOLATION"], !isolation.isEmpty {
            arguments += ["-default-isolation", isolation]
        }
        for condition in (state.buildSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "").split(separator: " ") {
            arguments += ["-D", String(condition)]
        }
        for feature in upcomingFeatures(state.buildSettings) { arguments += ["-enable-upcoming-feature", feature] }
        // shortcut: splits on spaces, so quoted flags with spaces break; upgrade if a project needs them.
        arguments += (state.buildSettings["OTHER_SWIFT_FLAGS"] ?? "").split(separator: " ").map(String.init).filter { $0 != "$(inherited)" }
        return arguments
    }

    private func removeOldPatches(keeping count: Int) {
        let directories = (try? FileManager.default.contentsOfDirectory(at: patches, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = directories.sorted { (modificationDate($0.path) ?? .distantPast) > (modificationDate($1.path) ?? .distantPast) }
        sorted.dropFirst(count).forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

/// `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` becomes `MemberImportVisibility`.
public func upcomingFeatures(_ buildSettings: [String: String]) -> [String] {
    var features = buildSettings.filter { $0.key.hasPrefix("SWIFT_UPCOMING_FEATURE_") && $0.value == "YES" }.map { setting in
        setting.key.dropFirst("SWIFT_UPCOMING_FEATURE_".count).split(separator: "_").map { $0.prefix(1) + $0.dropFirst().lowercased() }.joined()
    }
    if buildSettings["SWIFT_APPROACHABLE_CONCURRENCY"] == "YES" {
        features += ["DisableOutwardActorInference", "GlobalActorIsolatedTypesUsability", "InferIsolatedConformances",
                     "InferSendableFromCaptures", "NonisolatedNonsendingByDefault"]
    }
    return features.sorted()
}
