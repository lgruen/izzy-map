import MapLibre
import os

/// Routes MapLibre's log through `os.Logger`, minus the per-tile failure
/// lines of the LIVE LIST sources: every live tile that fails offline logs
/// two of them (map proof Q4), which would drown everything else. Failures
/// of anything else (a local pack, glyphs) stay visible.
nonisolated enum MapLogging {
    private static let logger = Logger(subsystem: "org.gruenschloss.izzymap", category: "MapLibre")

    static func install() {
        let config = MLNLoggingConfiguration.shared
        // warnings and errors only (the default, .none, would hide real problems)
        config.loggingLevel = .warning
        // Called on MapLibre's own threads: this closure must stay nonisolated.
        config.handler = { @Sendable level, _, _, message in
            guard !isLiveTileFailure(message) else { return }
            switch level {
            case .error, .fault: logger.error("\(message, privacy: .public)")
            case .warning: logger.warning("\(message, privacy: .public)")
            default: logger.debug("\(message, privacy: .public)")
            }
        }
    }

    /// "Failed to load tile 16/… for source topo-live: …" for a live source,
    /// and "Requesting: https://<live host>/… failed with error".
    static func isLiveTileFailure(
        _ message: String,
        liveSources: Set<String> = StyleBuilder.liveSourceIDs,
        liveHosts: Set<String> = StyleBuilder.liveHosts
    ) -> Bool {
        if message.contains("Failed to load tile"),
           let match = message.firstMatch(of: /for source ([^\s:]+)/) {
            return liveSources.contains(String(match.output.1))
        }
        if message.hasPrefix("Requesting: "), message.contains("failed with error"),
           let url = message.dropFirst("Requesting: ".count).split(separator: " ").first,
           let host = URL(string: String(url))?.host() {
            return liveHosts.contains(host)
        }
        return false
    }
}
