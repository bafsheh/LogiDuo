/// Assigns stable ``DeviceID``s to device observations across reconnects and
/// transport changes.
///
/// Reconciliation rules, applied in order:
/// 1. **Physical match.** An observation with a firmware identity resolves to the
///    record with the same ``PhysicalDeviceID``, whatever the endpoint — this is
///    how a device keeps its identity when moving between Bluetooth and a receiver.
/// 2. **Endpoint match.** An observation resolves to the record last seen on the
///    same endpoint with the same model product, provided the two physical
///    identities do not contradict each other. If the observation brings a
///    physical identity the record lacked, the record adopts it.
/// 3. **New device.** Otherwise a new identity is registered. If it takes over an
///    endpoint that another record was last seen on (for example a receiver slot
///    re-paired with another device), that record forgets the endpoint.
///
/// Known limitation: two identical devices without firmware identities that
/// swap the same endpoint are indistinguishable.
///
/// The registry is a value type; every operation is pure and deterministic.
public struct DeviceIdentityRegistry: Hashable, Sendable {
    /// How an observation was reconciled.
    public enum Outcome: Hashable, Sendable {
        /// Matched an existing record by firmware identity.
        case matchedPhysicalIdentity(transportChanged: Bool)
        /// Matched an existing record by endpoint and model.
        case matchedEndpoint
        /// Matched by endpoint and model, and the record adopted the observed firmware identity.
        case adoptedPhysicalIdentity
        /// Registered a new device.
        case registered
    }

    /// The result of reconciling one observation.
    public struct Resolution: Hashable, Sendable {
        /// The reconciled identity.
        public let identity: DeviceIdentity
        /// How it was reconciled.
        public let outcome: Outcome
        /// A device that was last seen on the same endpoint and lost it, if any.
        public let displaced: DeviceID?
    }

    private struct Record: Hashable, Sendable {
        var physical: PhysicalDeviceID?
        var endpoint: TransportEndpoint?
        var model: DeviceModel
    }

    private var records: [DeviceID: Record] = [:]

    /// Creates an empty registry.
    public init() {}

    /// The number of devices the registry knows.
    public var count: Int { records.count }

    /// The identity recorded for `id`, if known and currently bound to an endpoint.
    public func identity(for id: DeviceID) -> DeviceIdentity? {
        guard let record = records[id], let endpoint = record.endpoint else { return nil }
        return DeviceIdentity(id: id, physical: record.physical, endpoint: endpoint, model: record.model)
    }

    /// Reconciles `observation` with the known devices and records the result.
    public mutating func reconcile(_ observation: DeviceObservation) -> Resolution {
        if let physical = observation.physical, let id = recordID(withPhysical: physical) {
            let transportChanged = records[id]?.endpoint != observation.endpoint
            return bind(id, to: observation, outcome: .matchedPhysicalIdentity(transportChanged: transportChanged))
        }
        if let id = recordID(compatibleWith: observation) {
            let adopted = records[id]?.physical == nil && observation.physical != nil
            return bind(id, to: observation, outcome: adopted ? .adoptedPhysicalIdentity : .matchedEndpoint)
        }
        let id = uniqueID(derivedFrom: observation)
        return bind(id, to: observation, outcome: .registered)
    }

    private func recordID(withPhysical physical: PhysicalDeviceID) -> DeviceID? {
        records.first { $0.value.physical == physical }?.key
    }

    private func recordID(compatibleWith observation: DeviceObservation) -> DeviceID? {
        records.first { _, record in
            record.endpoint == observation.endpoint
                && record.model.product == observation.model.product
                && (record.physical == nil || observation.physical == nil)
        }?.key
    }

    private mutating func bind(_ id: DeviceID, to observation: DeviceObservation, outcome: Outcome) -> Resolution {
        let displaced = records.first { otherID, record in
            otherID != id && record.endpoint == observation.endpoint
        }?.key
        if let displaced {
            records[displaced]?.endpoint = nil
        }
        let physical = observation.physical ?? records[id]?.physical
        records[id] = Record(physical: physical, endpoint: observation.endpoint, model: observation.model)
        let identity = DeviceIdentity(
            id: id,
            physical: physical,
            endpoint: observation.endpoint,
            model: observation.model
        )
        return Resolution(identity: identity, outcome: outcome, displaced: displaced)
    }

    /// Derives a deterministic identifier, suffixed if it collides with a known one.
    private func uniqueID(derivedFrom observation: DeviceObservation) -> DeviceID {
        let base = Self.derivedRawValue(for: observation)
        var candidate = DeviceID(derived: base)
        var suffix = 2
        while records[candidate] != nil {
            candidate = DeviceID(derived: "\(base)~\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// `phy.<model>.<unit>` for firmware identities, `ep.<endpoint>.<product>` otherwise.
    static func derivedRawValue(for observation: DeviceObservation) -> String {
        if let physical = observation.physical {
            return DeviceID(physical: physical).rawValue
        }
        return "ep.\(observation.endpoint.fingerprint).\(hexString(observation.model.product.rawValue, digits: 4))"
    }
}
