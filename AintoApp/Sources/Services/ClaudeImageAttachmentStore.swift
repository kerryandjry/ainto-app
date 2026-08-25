import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ClaudeImageAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String

    init(id: UUID = UUID(), url: URL, displayName: String) {
        self.id = id
        self.url = url
        self.displayName = displayName
    }
}

enum ClaudeImageAttachmentError: LocalizedError, Equatable {
    case invalidImage
    case imageTooLarge
    case imageDimensionsTooLarge
    case tooManyImages
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The clipboard does not contain a supported PNG, JPEG, GIF, or WebP image."
        case .imageTooLarge:
            return "The image is larger than Claude Code's 5 MB attachment limit."
        case .imageDimensionsTooLarge:
            return "The image dimensions are too large. Use an image smaller than 8,192 pixels per side."
        case .tooManyImages:
            return "You can attach up to 4 images to one message."
        case .writeFailed:
            return "Ainto could not prepare the image attachment."
        }
    }
}

enum ClaudeImageAttachmentStore {
    private final class AttachmentLifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var isTerminating = false

        func permitsWrites() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !isTerminating
        }

        func beginTermination() {
            lock.lock()
            isTerminating = true
            lock.unlock()
        }
    }

    private static let lifecycle = AttachmentLifecycle()

    struct PasteboardImage: Sendable {
        enum Source: Sendable {
            case data(Data)
            case file(URL)
        }

        let source: Source
        let suggestedName: String

        init(data: Data, suggestedName: String) {
            source = .data(data)
            self.suggestedName = suggestedName
        }

        init(fileURL: URL, suggestedName: String) {
            source = .file(fileURL)
            self.suggestedName = suggestedName
        }

        func loadData() throws -> Data {
            switch source {
            case .data(let data):
                return data
            case .file(let url):
                return try Data(contentsOf: url, options: [.mappedIfSafe])
            }
        }
    }

    static let maximumAttachments = 4
    static let maximumFileSize = 5 * 1_024 * 1_024
    static let maximumPixelDimension = 8_192
    static let maximumPixelCount = 40_000_000

    private static let supportedPasteboardTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "clipboard.png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "clipboard.jpg"),
        (NSPasteboard.PasteboardType("public.webp"), "clipboard.webp"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "clipboard.gif"),
        (.tiff, "clipboard.tiff"),
    ]

    /// Reads complete image representations while the caller owns
    /// PasteboardAccess exclusive access. The returned bytes no longer depend
    /// on NSPasteboard's lazy providers.
    static func images(from pasteboard: NSPasteboard) -> [PasteboardImage] {
        var images: [PasteboardImage] = []
        itemLoop: for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            if let fileImage = imageFile(from: item, index: index) {
                images.append(fileImage)
                if images.count > maximumAttachments { break }
                continue
            }
            for (type, defaultName) in supportedPasteboardTypes {
                guard let data = item.data(forType: type) else { continue }
                images.append(PasteboardImage(data: data, suggestedName: defaultName))
                if images.count > maximumAttachments { break itemLoop }
                break
            }
        }

        // Some applications expose only a pasteboard-wide converted image.
        if images.isEmpty {
            for (type, defaultName) in supportedPasteboardTypes {
                guard let data = pasteboard.data(forType: type) else { continue }
                images.append(PasteboardImage(data: data, suggestedName: defaultName))
                break
            }
        }
        return images
    }

    static func createAttachment(
        from image: PasteboardImage,
        directory: URL = attachmentDirectory()
    ) throws -> ClaudeImageAttachment {
        guard let inputData = try? image.loadData(),
              let source = CGImageSourceCreateWithData(inputData as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source),
              let type = UTType(typeIdentifier as String),
              type.conforms(to: .image)
        else {
            throw ClaudeImageAttachmentError.invalidImage
        }
        try validateDimensions(of: source)

        let output: (data: Data, extension: String)
        if inputData.count <= maximumFileSize,
           [.png, .jpeg, .gif, .webP].contains(type) {
            output = (inputData, type.preferredFilenameExtension ?? "png")
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ClaudeImageAttachmentError.invalidImage
            }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                png,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw ClaudeImageAttachmentError.invalidImage
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ClaudeImageAttachmentError.invalidImage
            }
            output = (png as Data, "png")
        }

        guard output.data.count <= maximumFileSize else {
            throw ClaudeImageAttachmentError.imageTooLarge
        }

        guard lifecycle.permitsWrites() else {
            throw ClaudeImageAttachmentError.writeFailed
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(output.extension)
            try output.data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard lifecycle.permitsWrites() else {
                try? FileManager.default.removeItem(at: url)
                throw ClaudeImageAttachmentError.writeFailed
            }
            return ClaudeImageAttachment(url: url, displayName: image.suggestedName)
        } catch let error as ClaudeImageAttachmentError {
            throw error
        } catch {
            throw ClaudeImageAttachmentError.writeFailed
        }
    }

    static func remove(_ attachments: [ClaudeImageAttachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.url)
        }
    }

    static func removeAllAttachments() {
        try? FileManager.default.removeItem(at: attachmentDirectory())
    }

    static func beginTerminationCleanup() {
        lifecycle.beginTermination()
        removeAllAttachments()
    }

    static func thumbnailData(for url: URL, maximumDimension: Int = 192) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func prompt(text: String, attachments: [ClaudeImageAttachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let paths = attachments.enumerated().map { index, attachment in
            "Image \(index + 1): \(attachment.url.path)"
        }.joined(separator: "\n")
        let request = text.isEmpty ? "Describe the attached image." : text
        return """
        Use the Read tool to inspect the attached image file(s) before answering.
        \(paths)

        User request:
        \(request)
        """
    }

    static func attachmentDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("app.ainto.macos", isDirectory: true)
            .appendingPathComponent("ClaudeAttachments", isDirectory: true)
    }

    static func removeStaleAttachments(olderThan interval: TimeInterval = 24 * 60 * 60) {
        let directory = attachmentDirectory()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if values?.contentModificationDate.map({ $0 < cutoff }) ?? true {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func imageFile(from item: NSPasteboardItem, index: Int) -> PasteboardImage? {
        guard let value = item.string(forType: .fileURL),
              let url = URL(string: value),
              url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image)
        else { return nil }
        let name = url.lastPathComponent.isEmpty ? "image-\(index + 1)" : url.lastPathComponent
        return PasteboardImage(fileURL: url, suggestedName: name)
    }

    private static func validateDimensions(of source: CGImageSource) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else {
            throw ClaudeImageAttachmentError.invalidImage
        }
        guard width <= maximumPixelDimension,
              height <= maximumPixelDimension,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maximumPixelCount
        else {
            throw ClaudeImageAttachmentError.imageDimensionsTooLarge
        }
    }
}
