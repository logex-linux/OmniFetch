import SwiftUI
import AppKit
import ImageIO

/// Memory-cached, ImageIO-downsampled thumbnail loader.
/// Eliminates AsyncImage scroll flicker and avoids decoding 4K cover art on MainActor.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 240
        c.totalCostLimit = 24 * 1024 * 1024
        return c
    }()

    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let lock = NSLock()

    func cachedImage(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func load(urlString: String, maxPixelSize: Int = 260) async -> NSImage? {
        if let hit = cachedImage(for: urlString) {
            return hit
        }
        guard let url = URL(string: urlString) else { return nil }

        let task: Task<NSImage?, Never> = lock.withLock {
            if let existing = inFlight[urlString] { return existing }
            let created = Task.detached(priority: .utility) { () -> NSImage? in
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      !data.isEmpty else {
                    return nil
                }
                return Self.downsample(data: data, maxPixelSize: maxPixelSize)
            }
            inFlight[urlString] = created
            return created
        }

        let image = await task.value
        lock.withLock { inFlight[urlString] = nil }
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: urlString as NSString, cost: max(1, cost))
        }
        return image
    }

    private static func downsample(data: Data, maxPixelSize: Int) -> NSImage? {
        let sourceOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOpts as CFDictionary) else {
            return NSImage(data: data)
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct CachedThumbnailView: View {
    let urlString: String?
    var width: CGFloat = 96
    var height: CGFloat = 54
    var cornerRadius: CGFloat = OmniRadius.sm
    var isCollection: Bool = false
    var isAudioOnly: Bool = false
    var durationText: String? = nil

    @State private var loadedImage: NSImage?

    var body: some View {
        let image = urlString.flatMap { ThumbnailCache.shared.cachedImage(for: $0) } ?? loadedImage
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(OmniColor.surface)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .transition(.opacity)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: width >= 110 ? 20 : 16, weight: .regular))
                    .foregroundStyle(OmniColor.inkMuted.opacity(0.65))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let durationText, !durationText.isEmpty {
                Text(durationText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(red: 0.95, green: 0.97, blue: 0.98))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(red: 0.07, green: 0.09, blue: 0.11).opacity(0.84))
                    )
                    .padding(4)
            } else if isCollection {
                Image(systemName: "photo.stack")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.95, green: 0.97, blue: 0.98))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(red: 0.07, green: 0.09, blue: 0.11).opacity(0.84))
                    )
                    .padding(4)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(OmniColor.line, lineWidth: 1)
        )
        .task(id: urlString) {
            guard let urlString, !urlString.isEmpty else {
                loadedImage = nil
                return
            }
            if let hit = ThumbnailCache.shared.cachedImage(for: urlString) {
                loadedImage = hit
                return
            }
            let fetched = await ThumbnailCache.shared.load(
                urlString: urlString,
                maxPixelSize: Int(max(width, height) * 2.5)
            )
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.16)) {
                    loadedImage = fetched
                }
            }
        }
    }

    private var fallbackSymbol: String {
        if isAudioOnly { return "waveform" }
        if isCollection { return "photo.on.rectangle.angled" }
        return "film"
    }
}
