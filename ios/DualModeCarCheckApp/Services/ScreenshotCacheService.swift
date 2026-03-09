import Foundation
import UIKit

@MainActor
class ScreenshotCacheService {
    static let shared = ScreenshotCacheService()

    private let cacheDirectory: URL
    private let maxMemoryCacheCount = 100
    private let maxDiskCacheCount = 500
    private var memoryCache: [String: UIImage] = [:]
    private var accessOrder: [String] = []

    init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDir.appendingPathComponent("ScreenshotCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func store(_ image: UIImage, forKey key: String) {
        memoryCache[key] = image
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        evictMemoryCacheIfNeeded()

        Task.detached(priority: .utility) {
            let fileURL = self.fileURL(for: key)
            if let data = image.jpegData(compressionQuality: 0.5) {
                try? data.write(to: fileURL, options: .atomic)
            }
            await MainActor.run {
                self.evictDiskCacheIfNeeded()
            }
        }
    }

    func retrieve(forKey key: String) -> UIImage? {
        if let cached = memoryCache[key] {
            accessOrder.removeAll { $0 == key }
            accessOrder.append(key)
            return cached
        }

        let fileURL = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: fileURL.path()),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }

        memoryCache[key] = image
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        evictMemoryCacheIfNeeded()
        return image
    }

    func clearAll() {
        memoryCache.removeAll()
        accessOrder.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    var diskCacheSize: String {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return "0 KB"
        }
        var totalSize: Int64 = 0
        for file in files {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                totalSize += Int64(size)
            }
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }

    private func evictMemoryCacheIfNeeded() {
        while memoryCache.count > maxMemoryCacheCount, let oldest = accessOrder.first {
            memoryCache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }

    private func evictDiskCacheIfNeeded() {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let dir = cachesDir.appendingPathComponent("ScreenshotCache", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

            let jpgFiles = files.filter { $0.pathExtension == "jpg" }
            guard jpgFiles.count > self.maxDiskCacheCount else { return }

            let sorted = jpgFiles.sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return aDate < bDate
            }

            let toRemove = sorted.prefix(jpgFiles.count - self.maxDiskCacheCount)
            for file in toRemove {
                try? fm.removeItem(at: file)
            }
        }
    }

    var diskFileCount: Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else { return 0 }
        return files.filter { $0.pathExtension == "jpg" }.count
    }

    private nonisolated func fileURL(for key: String) -> URL {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("ScreenshotCache", isDirectory: true).appendingPathComponent("\(safeKey).jpg")
    }
}
