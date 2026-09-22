import Foundation

public struct ProjectFrameworkDetector: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func inspect(root: URL) -> ProjectFrameworkInspection {
        if isWordPress(root) {
            return .init(
                framework: "WordPress",
                confidence: .high,
                evidence: ["wp-admin/", "wp-includes/", wordpressConfigurationMarker(root)],
                suggestedDocumentRoot: ""
            )
        }

        let markers = [
            "artisan": fileManager.fileExists(atPath: root.appendingPathComponent("artisan").path),
            "composer.json": fileManager.fileExists(atPath: root.appendingPathComponent("composer.json").path),
            "bootstrap/": isDirectory(root.appendingPathComponent("bootstrap", isDirectory: true)),
            "config/": isDirectory(root.appendingPathComponent("config", isDirectory: true)),
            "public/index.php": fileManager.fileExists(atPath: root.appendingPathComponent("public/index.php").path)
        ]
        var evidence = markers.filter(\.value).map(\.key).sorted()
        var composerPHP: String?
        if let object = jsonObject(at: root.appendingPathComponent("composer.json")),
           let requirements = object["require"] as? [String: Any] {
            if let php = requirements["php"] as? String {
                composerPHP = php
                evidence.append("composer.json require.php")
            }
            if requirements["laravel/framework"] as? String != nil {
                evidence.append("composer.json laravel/framework")
            }
        }
        let laravel = markers["artisan"] == true
            && markers["bootstrap/"] == true
            && markers["config/"] == true
            && markers["public/index.php"] == true
        if laravel {
            return .init(framework: "Laravel", confidence: .high, evidence: Array(Set(evidence)).sorted(), suggestedDocumentRoot: "public/", composerPHPRequirement: composerPHP)
        }
        if markers.values.filter({ $0 }).count >= 2 {
            return .init(framework: "Generic PHP", confidence: .medium, evidence: Array(Set(evidence)).sorted(), suggestedDocumentRoot: isDirectory(root.appendingPathComponent("public", isDirectory: true)) ? "public/" : nil, composerPHPRequirement: composerPHP)
        }

        if let node = inspectNodeWebProject(root) { return node }
        return .init(framework: "Generic/Unknown", confidence: .low, evidence: evidence, composerPHPRequirement: composerPHP)
    }

    public func isRecognizedProject(_ inspection: ProjectFrameworkInspection) -> Bool {
        inspection.confidence == .high || inspection.confidence == .medium
    }

    private func isWordPress(_ root: URL) -> Bool {
        let configured = fileManager.fileExists(atPath: root.appendingPathComponent("wp-config.php").path)
            || fileManager.fileExists(atPath: root.appendingPathComponent("wp-config-sample.php").path)
        return configured
            && isDirectory(root.appendingPathComponent("wp-admin", isDirectory: true))
            && isDirectory(root.appendingPathComponent("wp-includes", isDirectory: true))
    }

    private func wordpressConfigurationMarker(_ root: URL) -> String {
        fileManager.fileExists(atPath: root.appendingPathComponent("wp-config.php").path) ? "wp-config.php" : "wp-config-sample.php"
    }

    private func inspectNodeWebProject(_ root: URL) -> ProjectFrameworkInspection? {
        guard let package = jsonObject(at: root.appendingPathComponent("package.json")) else { return nil }
        let dependencies = (package["dependencies"] as? [String: Any] ?? [:])
            .merging(package["devDependencies"] as? [String: Any] ?? [:]) { current, _ in current }
        let frameworks: [(key: String, name: String)] = [
            ("next", "Next.js"), ("nuxt", "Nuxt"), ("@sveltejs/kit", "SvelteKit"),
            ("astro", "Astro"), ("react", "React"), ("vue", "Vue")
        ]
        guard let match = frameworks.first(where: { dependencies[$0.key] != nil }) else { return nil }
        return .init(framework: match.name, confidence: .medium, evidence: ["package.json \(match.key)"])
    }

    private func jsonObject(at url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) <= 1_000_000,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
