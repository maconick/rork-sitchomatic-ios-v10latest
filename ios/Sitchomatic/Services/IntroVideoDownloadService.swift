import Foundation
import Observation

@Observable
final class IntroVideoDownloadService {
    static let shared = IntroVideoDownloadService()

    private(set) var isDownloading: Bool = false
    private(set) var downloadProgress: Double = 0
    private(set) var lastError: String?

    private static let videoFileName = "intro_video.mp4"

    private static let remoteURL = URL(string: "https://sitchomatic-assets.s3.amazonaws.com/intro_video.mp4")

    var isVideoCached: Bool {
        FileManager.default.fileExists(atPath: Self.cachedVideoURL.path())
    }

    static var cachedVideoURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(videoFileName)
    }

    private init() {}

    func downloadIfNeeded() async {
        guard !isVideoCached, !isDownloading else { return }
        guard let remoteURL = Self.remoteURL else {
            lastError = "No download URL configured"
            return
        }

        isDownloading = true
        downloadProgress = 0
        lastError = nil

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: remoteURL, delegate: nil)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                lastError = "Download failed (HTTP \(httpResponse.statusCode))"
                isDownloading = false
                return
            }

            let destination = Self.cachedVideoURL
            if FileManager.default.fileExists(atPath: destination.path()) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            downloadProgress = 1.0
            isDownloading = false
        } catch is CancellationError {
            isDownloading = false
        } catch {
            lastError = error.localizedDescription
            isDownloading = false
        }
    }

    func deleteCache() {
        let url = Self.cachedVideoURL
        try? FileManager.default.removeItem(at: url)
        downloadProgress = 0
    }
}
