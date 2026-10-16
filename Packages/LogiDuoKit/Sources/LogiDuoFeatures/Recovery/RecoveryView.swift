public import LogiDuoDomain
public import SwiftUI

/// The device recovery screen: journal status, exact restore and emergency reset.
public struct RecoveryView: View {
    @Bindable private var model: RecoveryViewModel

    /// Creates the view.
    public init(model: RecoveryViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            if !model.writesEnabled {
                Section {
                    Label {
                        Text("recovery.writesDisabled", bundle: .module)
                    } icon: {
                        Image(systemName: "lock").accessibilityHidden(true)
                    }
                }
            }
            journalSection
            devicesSection
            if let proposal = model.proposal {
                RecoveryPlanSection(proposal: proposal, model: model)
            }
            RecoveryPhaseSection(phase: model.phase)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("recovery.screen")
        .task { await model.refresh() }
        .confirmationDialog(
            Text("recovery.confirm.title", bundle: .module),
            isPresented: $model.isConfirmingReset,
            presenting: model.proposal
        ) { _ in
            Button(role: .destructive) {
                Task { await model.confirmEmergencyReset() }
            } label: {
                Text("recovery.confirm.reset", bundle: .module)
            }
            Button(role: .cancel) {
                model.declineEmergencyReset()
            } label: {
                Text("recovery.confirm.decline", bundle: .module)
            }
        } message: { proposal in
            Text("recovery.confirm.message \(proposal.changes.count) \(proposal.device.name)", bundle: .module)
        }
    }

    private var journalSection: some View {
        Section {
            switch model.journal {
            case .clean:
                Text("recovery.journal.clean", bundle: .module)
            case .pending(let entries):
                Text("recovery.journal.pending \(entries)", bundle: .module)
            case .corrupted:
                Text("recovery.journal.corrupted", bundle: .module)
                Button {
                    Task { await model.acknowledgeCorruption() }
                } label: {
                    Text("recovery.journal.acknowledge", bundle: .module)
                }
            }
        } header: {
            Text("recovery.journal.header", bundle: .module)
        }
    }

    private var devicesSection: some View {
        Section {
            if model.devices.isEmpty {
                Text("recovery.devices.none", bundle: .module)
            }
            ForEach(model.devices) { device in
                LabeledContent {
                    HStack {
                        Button {
                            Task { await model.restore(device.id) }
                        } label: {
                            Text("recovery.restore", bundle: .module)
                        }
                        .disabled(device.pendingRecords == 0 || model.phase == .working)
                        Button {
                            Task { await model.reviewEmergencyReset(device.id) }
                        } label: {
                            Text("recovery.review", bundle: .module)
                        }
                        .disabled(model.phase == .working)
                    }
                } label: {
                    Text(device.name)
                    Text("recovery.devices.pending \(device.pendingRecords)", bundle: .module)
                }
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Text("recovery.devices.refresh", bundle: .module)
            }
        } header: {
            Text("recovery.devices.header", bundle: .module)
        }
    }
}

/// The read-only plan of an emergency reset.
private struct RecoveryPlanSection: View {
    let proposal: EmergencyResetProposal
    let model: RecoveryViewModel

    var body: some View {
        Section {
            Text("recovery.plan.explanation", bundle: .module)
            LabeledContent {
                Text(proposal.device.model.description)
            } label: {
                Text("recovery.plan.verifiedModel", bundle: .module)
            }
            ForEach(proposal.controls, id: \.control) { control in
                LabeledContent {
                    Text(control.plan.titleKey, bundle: .module)
                } label: {
                    Text(control.control.titleKey, bundle: .module)
                }
            }
            if proposal.journalCorrupted {
                Text("recovery.plan.journalCorrupted", bundle: .module)
            }
            HStack {
                Button(role: .destructive) {
                    model.requestConfirmation()
                } label: {
                    Text("recovery.plan.reset \(proposal.changes.count)", bundle: .module)
                }
                .disabled(proposal.changes.isEmpty)
                Button {
                    model.declineEmergencyReset()
                } label: {
                    Text("recovery.plan.cancel", bundle: .module)
                }
            }
        } header: {
            Text("recovery.plan.header \(proposal.device.name)", bundle: .module)
        }
    }
}

/// The outcome of the last step.
private struct RecoveryPhaseSection: View {
    let phase: RecoveryViewModel.Phase

    var body: some View {
        switch phase {
        case .idle, .reviewing:
            EmptyView()
        case .working:
            Section { ProgressView() }
        case .blocked(let block):
            Section {
                Text(block.titleKey, bundle: .module)
            }
        case .finished(let result):
            Section {
                Text(result.isComplete ? "recovery.result.complete" : "recovery.result.incomplete", bundle: .module)
                ForEach(result.outcomes.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { control in
                    LabeledContent {
                        Text(result.outcomes[control]?.titleKey ?? "recovery.outcome.failed", bundle: .module)
                    } label: {
                        Text(control.titleKey, bundle: .module)
                    }
                }
                if result.otherFailures > 0 || result.journalSaveFailed {
                    Text("recovery.result.recordsKept", bundle: .module)
                }
            } header: {
                Text("recovery.result.header", bundle: .module)
            }
        }
    }
}

extension DeviceControlID {
    var titleKey: LocalizedStringKey {
        switch rawValue {
        case 0x00C3: "recovery.control.gesture"
        case 0x00C4: "recovery.control.modeShift"
        case 0x00D7: "recovery.control.virtualGesture"
        default: "recovery.control.other \(description)"
        }
    }
}

extension RecoveryControlPlan {
    var titleKey: LocalizedStringKey {
        switch self {
        case .willReset: "recovery.plan.willReset"
        case .alreadyNative: "recovery.plan.alreadyNative"
        case .skippedPersistent: "recovery.plan.skippedPersistent"
        case .skippedRemapped: "recovery.plan.skippedRemapped"
        case .skippedNotDivertable: "recovery.plan.skippedNotDivertable"
        case .skippedUnexpected: "recovery.plan.skippedUnexpected"
        }
    }
}

extension RecoveryControlOutcome {
    var titleKey: LocalizedStringKey {
        switch self {
        case .restored: "recovery.outcome.restored"
        case .alreadyNative: "recovery.outcome.alreadyNative"
        case .skipped: "recovery.outcome.skipped"
        case .changedSincePlanning: "recovery.outcome.changed"
        case .failed: "recovery.outcome.failed"
        }
    }
}

extension RecoveryBlock {
    var titleKey: LocalizedStringKey {
        switch self {
        case .writesDisabled: "recovery.block.writesDisabled"
        case .identityUnverified: "recovery.block.identityUnverified"
        case .notConfirmed: "recovery.block.notConfirmed"
        case .deviceUnavailable: "recovery.block.deviceUnavailable"
        case .journalCorrupted: "recovery.block.journalCorrupted"
        case .unsupportedDevice: "recovery.block.unsupportedDevice"
        }
    }
}
