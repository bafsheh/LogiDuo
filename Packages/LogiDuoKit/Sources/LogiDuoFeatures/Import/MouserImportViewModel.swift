public import Foundation
public import LogiDuoDomain
public import Observation

/// Presentation state for importing Mouser settings: preview first, apply on confirmation.
@MainActor
@Observable
public final class MouserImportViewModel {
    /// Where the import stands.
    public enum Phase: Hashable, Sendable {
        case idle
        case loading
        case preview(MouserImportPreview)
        case failed(MouserImportFailure)
        case imported
    }

    /// The current phase.
    public private(set) var phase: Phase = .idle
    /// Whether settings from before an import can be restored.
    public private(set) var canUndo = false

    private let service: any MouserImportServicing

    /// Creates a view model.
    public init(service: any MouserImportServicing) {
        self.service = service
    }

    /// The preview on screen, if any.
    public var preview: MouserImportPreview? {
        if case .preview(let preview) = phase { return preview }
        return nil
    }

    /// Reads Mouser's configuration from its usual place (nothing is changed).
    public func loadDefault() async {
        phase = .loading
        show(await service.previewDefaultFile())
        canUndo = await service.canUndoImport()
    }

    /// Reads a chosen Mouser configuration file (nothing is changed).
    public func load(_ url: URL) async {
        phase = .loading
        show(await service.preview(fileAt: url))
    }

    /// Imports the previewed configuration (after a backup of the current settings).
    public func confirm() async {
        guard let preview else { return }
        phase = .loading
        switch await service.apply(preview) {
        case .success: phase = .imported
        case .failure(let failure): phase = .failed(failure)
        }
        canUndo = await service.canUndoImport()
    }

    /// Restores the settings from before the last import.
    public func undo() async {
        if await service.undoImport() { phase = .idle }
        canUndo = await service.canUndoImport()
    }

    /// Discards the preview; nothing is changed.
    public func cancel() {
        phase = .idle
    }

    private func show(_ result: Result<MouserImportPreview, MouserImportFailure>) {
        switch result {
        case .success(let preview): phase = .preview(preview)
        case .failure(let failure): phase = .failed(failure)
        }
    }
}
