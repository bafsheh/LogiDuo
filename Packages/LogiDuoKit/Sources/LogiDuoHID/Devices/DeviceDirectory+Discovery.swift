import LogiDuoDomain
import LogiDuoHIDPP

/// Attaching interfaces: direct devices get one session, receivers are probed slot by slot.
extension DeviceDirectory {
    func attach(_ descriptor: HIDInterfaceDescriptor) async {
        guard attachments[descriptor.registryID] == nil else { return }
        switch HIDInterfaceClassifier.role(of: descriptor) {
        case .directDevice(let link, let framing):
            let key = EndpointKey(rawValue: descriptor.linkFingerprint ?? "registry-\(descriptor.registryID)")
            guard let key else { return }
            let session = makeSession(descriptor, framing: framing, index: .direct, endpoint: .direct(link, key))
            attachments[descriptor.registryID] = Attachment(descriptor: descriptor, sessions: [session])
            await launch(session, for: descriptor.registryID)
        case .receiver(_, let framing):
            attachments[descriptor.registryID] = Attachment(descriptor: descriptor, sessions: [])
            await probeReceiver(descriptor, framing: framing)
        case .logitechWithoutHIDPP, .unrelated:
            return
        }
    }

    /// Starts `session` unless the directory stopped or the interface left meanwhile.
    private func launch(_ session: DeviceSession<SessionClock>, for registryID: UInt64) async {
        await session.setDiversion(diversion)
        guard isRunning, attachments[registryID]?.sessions.contains(where: { $0 === session }) == true else {
            await session.close()
            return
        }
        await session.start()
    }

    /// Pings the receiver's slots that have no session yet on one temporary channel;
    /// each answering slot gets a session. Runs again on refresh, so devices that were
    /// asleep or on another host when the receiver appeared are found later.
    private func probeReceiver(_ descriptor: HIDInterfaceDescriptor, framing: HIDPPFraming) async {
        guard
            let receiverID = ReceiverID(rawValue: descriptor.linkFingerprint ?? "receiver-\(descriptor.registryID)"),
            let probeTransport = try? openGuarded(descriptor.registryID, framing: framing)
        else { return }
        let receiver = ReceiverDescriptor(id: receiverID, hardware: descriptor.hardware)
        let known = Set(attachments[descriptor.registryID]?.sessions.map(\.endpoint) ?? [])
        let channel = HIDPPChannel(transport: probeTransport, clock: clock)
        await channel.start()
        var found: [DeviceSession<SessionClock>] = []
        for raw in UInt8(1)...6 {
            guard let slot = ReceiverSlot(rawValue: raw), !known.contains(.receiver(receiver, slot)) else { continue }
            let index = DeviceIndex(receiverSlot: slot)
            guard
                (try? await RootFeature.protocolVersion(via: channel, device: index, timeout: .milliseconds(600)))
                    != nil
            else { continue }
            found.append(makeSession(descriptor, framing: framing, index: index, endpoint: .receiver(receiver, slot)))
        }
        await channel.close()
        guard isRunning, attachments[descriptor.registryID] != nil else {
            for session in found { await session.close() }
            return
        }
        attachments[descriptor.registryID]?.sessions += found
        for session in found { await launch(session, for: descriptor.registryID) }
    }

    /// Looks for newly reachable devices behind every receiver.
    func reprobeReceivers() async {
        for attachment in attachments.values {
            if case .receiver(_, let framing) = HIDInterfaceClassifier.role(of: attachment.descriptor) {
                await probeReceiver(attachment.descriptor, framing: framing)
            }
        }
    }
}
