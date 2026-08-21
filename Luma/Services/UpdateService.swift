import AppKit
import Foundation
import Observation

private struct LumaReleaseManifest: Decodable {
    var latestVersion: String
    var downloadURL: URL
    var notes: String
}

@MainActor
@Observable
final class UpdateService {
    private static let defaultFeedURL = URL(
        string: "https://raw.githubusercontent.com/MatiasEz/luma/main/release.json"
    )!

    enum State: Equatable {
        case idle
        case checking
        case current
        case available(version: String, notes: String)
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private var downloadURL: URL?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }

    func check() async {
        let configuredURL = (Bundle.main.object(forInfoDictionaryKey: "LUMAUpdateFeedURL") as? String)
            .flatMap(URL.init(string:))
        let url = configuredURL ?? Self.defaultFeedURL

        state = .checking
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let manifest = try JSONDecoder().decode(LumaReleaseManifest.self, from: data)
            if manifest.latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                downloadURL = manifest.downloadURL
                state = .available(version: manifest.latestVersion, notes: manifest.notes)
            } else {
                downloadURL = nil
                state = .current
            }
        } catch {
            state = .unavailable("No pude revisar el canal ahora. La app sigue funcionando normalmente.")
        }
    }

    func openDownload() {
        guard let downloadURL else { return }
        NSWorkspace.shared.open(downloadURL)
    }
}
