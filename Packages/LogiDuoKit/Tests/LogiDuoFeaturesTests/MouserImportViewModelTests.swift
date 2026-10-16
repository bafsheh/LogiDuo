import Foundation
import LogiDuoDomain
import Testing

@testable import LogiDuoFeatures

private actor FakeImporter: MouserImportServicing {
    var applied: [MouserImportPreview] = []
    var undone = 0
    let result: Result<MouserImportPreview, MouserImportFailure>

    init(_ result: Result<MouserImportPreview, MouserImportFailure>) { self.result = result }

    func previewDefaultFile() -> Result<MouserImportPreview, MouserImportFailure> { result }
    func preview(fileAt url: URL) -> Result<MouserImportPreview, MouserImportFailure> { result }
    func apply(_ preview: MouserImportPreview) -> Result<Void, MouserImportFailure> {
        applied.append(preview)
        return .success(())
    }
    func canUndoImport() -> Bool { !applied.isEmpty && undone == 0 }
    func undoImport() -> Bool {
        undone += 1
        return true
    }
}

@MainActor
@Suite("MouserImportViewModel")
struct MouserImportViewModelTests {
    private static let preview = try? MouserImporter.preview(
        Data(#"{"version": 9, "profiles": {"default": {"mappings": {"middle": "copy"}}}}"#.utf8)
    )

    @Test("loading shows a preview and changes nothing until confirmed")
    func previewThenConfirm() async throws {
        let preview = try #require(Self.preview)
        let service = FakeImporter(.success(preview))
        let model = MouserImportViewModel(service: service)

        await model.loadDefault()
        #expect(model.preview == preview)
        #expect(await service.applied.isEmpty)

        await model.confirm()
        #expect(model.phase == .imported)
        #expect(await service.applied == [preview])
        #expect(model.canUndo)

        await model.undo()
        #expect(await service.undone == 1)
        #expect(!model.canUndo)
    }

    @Test("cancelling imports nothing")
    func cancel() async throws {
        let service = FakeImporter(.success(try #require(Self.preview)))
        let model = MouserImportViewModel(service: service)
        await model.loadDefault()
        model.cancel()
        await model.confirm()
        #expect(await service.applied.isEmpty)
    }

    @Test("failures are shown")
    func failure() async {
        let model = MouserImportViewModel(service: FakeImporter(.failure(.invalid(.newerVersion(12)))))
        await model.loadDefault()
        #expect(model.phase == .failed(.invalid(.newerVersion(12))))
    }
}
