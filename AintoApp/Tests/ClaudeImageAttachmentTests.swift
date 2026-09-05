import AppKit
import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

@MainActor
final class ClaudeImageAttachmentTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII="
    )!

    func testCreatesPrivateTemporaryAttachment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let attachment = try ClaudeImageAttachmentStore.createAttachment(
            from: .init(data: onePixelPNG, suggestedName: "screenshot.png"),
            directory: directory
        )

        XCTAssertEqual(attachment.displayName, "screenshot.png")
        XCTAssertEqual(try Data(contentsOf: attachment.url), onePixelPNG)
        let attributes = try FileManager.default.attributesOfItem(atPath: attachment.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRejectsInvalidImageData() {
        XCTAssertThrowsError(
            try ClaudeImageAttachmentStore.createAttachment(
                from: .init(data: Data("not an image".utf8), suggestedName: "bad.png"),
                directory: FileManager.default.temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeImageAttachmentError, .invalidImage)
        }
    }

    func testRejectsExcessiveImageDimensions() throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: ClaudeImageAttachmentStore.maximumPixelDimension + 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertThrowsError(
            try ClaudeImageAttachmentStore.createAttachment(
                from: .init(data: data, suggestedName: "wide.png"),
                directory: FileManager.default.temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeImageAttachmentError, .imageDimensionsTooLarge)
        }
    }

    func testReadsImageFromNamedPasteboardWithoutTouchingGeneralPasteboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setData(onePixelPNG, forType: .png)
        pasteboard.writeObjects([item])

        let images = ClaudeImageAttachmentStore.images(from: pasteboard)

        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(try images.first?.loadData(), onePixelPNG)
    }

    func testPasteboardReadStopsAfterOverflowSentinel() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let items = (0...ClaudeImageAttachmentStore.maximumAttachments).map { _ in
            let item = NSPasteboardItem()
            item.setData(onePixelPNG, forType: .png)
            return item
        }
        pasteboard.writeObjects(items)

        let images = ClaudeImageAttachmentStore.images(from: pasteboard)

        XCTAssertEqual(images.count, ClaudeImageAttachmentStore.maximumAttachments + 1)
    }

    func testCreatesBoundedThumbnailData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = try ClaudeImageAttachmentStore.createAttachment(
            from: .init(data: onePixelPNG, suggestedName: "screenshot.png"),
            directory: directory
        )

        let thumbnail = try XCTUnwrap(
            ClaudeImageAttachmentStore.thumbnailData(for: attachment.url, maximumDimension: 32)
        )

        XCTAssertFalse(thumbnail.isEmpty)
        XCTAssertLessThanOrEqual(thumbnail.count, ClaudeImageAttachmentStore.maximumFileSize)
    }

    func testPromptIncludesEveryAttachmentAndUserRequest() {
        let attachments = [
            ClaudeImageAttachment(
                url: URL(fileURLWithPath: "/tmp/ainto-image-one.png"),
                displayName: "one.png"
            ),
            ClaudeImageAttachment(
                url: URL(fileURLWithPath: "/tmp/ainto-image-two.jpg"),
                displayName: "two.jpg"
            ),
        ]

        let prompt = ClaudeImageAttachmentStore.prompt(
            text: "Compare these layouts",
            attachments: attachments
        )

        XCTAssertTrue(prompt.contains("Image 1: /tmp/ainto-image-one.png"))
        XCTAssertTrue(prompt.contains("Image 2: /tmp/ainto-image-two.jpg"))
        XCTAssertTrue(prompt.contains("Compare these layouts"))
    }

    func testImageOnlyPromptHasUsefulDefaultRequest() {
        let attachment = ClaudeImageAttachment(
            url: URL(fileURLWithPath: "/tmp/ainto-image.png"),
            displayName: "image.png"
        )

        let prompt = ClaudeImageAttachmentStore.prompt(text: "", attachments: [attachment])

        XCTAssertTrue(prompt.contains("Describe the attached image."))
    }

    func testPendingImportBlocksSendingAndSecondImport() {
        let viewModel = SearchViewModel(cleanStaleAttachments: false)
        viewModel.searchMode = .claude
        viewModel.query = "Do not send yet"

        XCTAssertTrue(viewModel.beginClaudeImageImport())
        XCTAssertFalse(viewModel.beginClaudeImageImport())
        viewModel.claudeAsk()

        XCTAssertTrue(viewModel.claudeMessages.isEmpty)
        XCTAssertTrue(viewModel.claudeAttachmentIsImporting)
        viewModel.cancelClaudeImageImport()
    }

    func testLeavingClaudeConversationRemovesAttachmentFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try onePixelPNG.write(to: url)
        let attachment = ClaudeImageAttachment(url: url, displayName: "image.png")
        let viewModel = SearchViewModel(cleanStaleAttachments: false)
        viewModel.page = .claude
        viewModel.claudeMessages = [
            ClaudeMessage(role: .user, text: "Inspect this", attachments: [attachment]),
        ]

        viewModel.goBack()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(viewModel.claudeMessages.isEmpty)
    }

    func testSwitchingOutOfDraftAIModeRemovesPendingAttachments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try onePixelPNG.write(to: url)
        let attachment = ClaudeImageAttachment(url: url, displayName: "image.png")
        let viewModel = SearchViewModel(cleanStaleAttachments: false)
        viewModel.searchMode = .claude
        viewModel.claudePendingAttachments = [attachment]

        viewModel.toggleSearchMode()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(viewModel.claudePendingAttachments.isEmpty)
    }
}
