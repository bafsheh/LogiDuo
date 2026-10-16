import LogiDuoDomain
import LogiDuoHIDPP

/// Where diversion happens on one device, learned when it connects.
struct DiversionContext: Sendable {
    let target: ConfigurableDevice
    let ledger: RestorationLedger
}

/// Button diversion for controls macOS does not report (gesture, mode shift).
///
/// Only runs with write authorization: every divert goes through
/// ``ControlDivertTransaction`` (durable record, verified read-back), and the
/// device's notifications are decoded into button and motion events.
extension DeviceSession {
    /// Makes the diverted set equal to `buttons` (empty restores everything).
    func setDiversion(_ buttons: Set<MouseButton>) async {
        wantedDiversion = buttons
        await applyDiversion()
    }

    /// Restores every diverted control (on stop and quit).
    func restoreDiversion() async {
        wantedDiversion = []
        await applyDiversion()
    }

    /// Re-establishes the wanted diversion after (re)connecting: temporary diverts do not survive a reconnect.
    ///
    /// Runs one pass at a time: the actor is reentrant at every device request, so a
    /// request that arrives during a pass marks the work dirty and waits while the
    /// running pass repeats, instead of interleaving with a stale view of what is diverted.
    func applyDiversion() async {
        guard !applyingDiversion else {
            // Joins the running pass and returns only once the device matches the latest request.
            diversionDirty = true
            await withCheckedContinuation { diversionWaiters.append($0) }
            return
        }
        applyingDiversion = true
        repeat {
            diversionDirty = false
            await applyDiversionPass()
        } while diversionDirty
        applyingDiversion = false
        let waiters = diversionWaiters
        diversionWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func applyDiversionPass() async {
        guard let context = diversionContext, await connection.state == .connected else { return }
        let transaction = ControlDivertTransaction(
            connection: connection,
            target: context.target,
            ledger: context.ledger,
            authorization: .enabled,
            timeout: .seconds(2)
        )
        let wanted = Set(wantedDiversion.compactMap(DivertedControlsDecoder.control(for:)))
        // Only controls this session diverted are restored here; records from an earlier
        // run are left for the recovery screen (nothing is restored automatically).
        let unwanted = divertedThisRun.subtracting(wanted)
        if !unwanted.isEmpty {
            _ = await transaction.restore(controls: unwanted)
            activeDiversion.subtract(unwanted)
            divertedThisRun.subtract(unwanted)
        }
        guard !wanted.isEmpty,
            let controls = try? await ReprogControlsFeature.controls(
                via: connection,
                index: context.target.reprogIndex,
                deviceIndex: deviceIndex
            )
        else { return }
        for control in controls where wanted.contains(control.control) && !activeDiversion.contains(control.control) {
            let command: ReportingCommand = control.flags.contains(.rawXY) ? .divertWithRawXY : .divertButtonOnly
            if (try? await transaction.divert(control, with: command)) != nil {
                activeDiversion.insert(control.control)
                divertedThisRun.insert(control.control)
            }
        }
    }

    /// Decodes a device notification into input events.
    func decode(_ notification: HIDPPNotification) -> [InputEvent] {
        guard case .message(let message) = notification, let reprog = diversionContext?.target.reprogIndex,
            message.featureIndex == reprog
        else { return [] }
        return decoder.decode(function: message.function.rawValue, parameters: message.parameters)
    }
}
