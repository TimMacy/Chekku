import AppKit
import SwiftUI

struct ArtworkView: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [AppStyle.surface, AppStyle.accent.opacity(0.28)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "tv").font(.system(size: 32, weight: .light)).foregroundStyle(.white.opacity(0.3))
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await ArtworkCache.image(at: url)
        }
    }
}

@MainActor
private enum ArtworkCache {
    static let memory = NSCache<NSURL, NSImage>()
    static let responses = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024,
                                    directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                        .appendingPathComponent("com.chekku.app/artwork", isDirectory: true))
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = responses
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    static func image(at url: URL) async -> NSImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            responses.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
            memory.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        } catch {
            return nil
        }
    }
}
