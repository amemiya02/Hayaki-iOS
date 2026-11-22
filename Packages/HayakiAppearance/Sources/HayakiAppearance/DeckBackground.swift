import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A device-local choice stored next to the active profile’s collection.
public struct DeckBackground: Sendable {
    public static let revisionKey = "hayaki.deckBackground.revision"
    private let file: URL

    public init(collectionFolder: URL) {
        file = collectionFolder.appendingPathComponent("DeckListBackground.jpg")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    @concurrent
    public func image() async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @concurrent
    public func replace(with url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        try store(source)
    }

    /// Stores an image's encoded bytes, such as a photo from the library.
    @concurrent
    public func replace(with data: Data) async throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CocoaError(.fileReadCorruptFile) }
        try store(source)
    }

    private func store(_ source: CGImageSource) throws {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: file, options: .atomic)
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: file)
    }
}
