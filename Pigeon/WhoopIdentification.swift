import CoreBluetooth
import Foundation

/// Helper utilities for identifying WHOOP devices
struct WhoopIdentification {

    /// WHOOP device generations
    enum Generation: String {
        case gen4 = "WHOOP 4.0"
        case gen5 = "WHOOP 5.0"
        case unknown = "Unknown"
    }

    // WHOOP service UUID strings
    static let gen5ServiceUUID = "fd4b0001-cce1-4033-93ce-002d5875f58a"
    static let gen4ServiceUUID = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"

    static let whoopServiceCBUUIDs: [CBUUID] = [
        CBUUID(string: gen5ServiceUUID),
        CBUUID(string: gen4ServiceUUID),
    ]

    static func isWhoopService(_ uuid: CBUUID) -> Bool {
        whoopServiceCBUUIDs.contains(uuid)
    }

    /// Collect service UUIDs from an advertisement packet (Goose-style).
    static func advertisedServiceUUIDs(from advertisementData: [String: Any]) -> [CBUUID] {
        var uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        uuids.append(contentsOf: advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        uuids.append(contentsOf: advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? [])
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            uuids.append(contentsOf: serviceData.keys)
        }
        return uuids
    }

    /// Advertised local name from BLE packet.
    static func advertisedLocalName(from advertisementData: [String: Any]) -> String? {
        advertisementData[CBAdvertisementDataLocalNameKey] as? String
    }

    /// Returns a human-readable reason when a peripheral looks like WHOOP, else nil.
    static func identityEvidence(
        peripheralID: UUID,
        peripheralName: String?,
        fallbackName: String?,
        advertisedServices: [CBUUID],
        whoopCandidateIDs: Set<UUID>,
        rememberedDeviceID: UUID?,
        rememberedDeviceName: String?,
        rememberedDeviceValidated: Bool
    ) -> String? {
        if advertisedServices.contains(where: isWhoopService) {
            return "advertised WHOOP service"
        }
        if whoopCandidateIDs.contains(peripheralID) {
            return "cached WHOOP service match"
        }
        if let peripheralName, isWhoopName(peripheralName) {
            return "peripheral name \(peripheralName)"
        }
        if let fallbackName, isWhoopName(fallbackName) {
            return "advertised name \(fallbackName)"
        }
        if rememberedDeviceID == peripheralID,
           rememberedDeviceValidated || isWhoopName(rememberedDeviceName ?? "") {
            return "validated remembered WHOOP"
        }
        return nil
    }

    /// Check if a device name indicates it's a WHOOP device
    static func isWhoopName(_ name: String) -> Bool {
        let uppercased = name.uppercased()
        return uppercased.contains("WHOOP")
    }

    /// Detect WHOOP generation from service UUIDs
    static func detectGeneration(from serviceUUIDs: [String]) -> Generation {
        let uuids = serviceUUIDs.map { $0.lowercased() }

        if uuids.contains(gen5ServiceUUID.lowercased()) {
            return .gen5
        } else if uuids.contains(gen4ServiceUUID.lowercased()) {
            return .gen4
        } else {
            return .unknown
        }
    }

    /// Sanitize WHOOP display name (remove generic prefixes)
    static func sanitizeDisplayName(_ name: String) -> String {
        var sanitized = name.trimmingCharacters(in: .whitespaces)

        // Remove common BLE prefixes
        let prefixes = ["BLE-", "BT-", "Device-"]
        for prefix in prefixes {
            if sanitized.hasPrefix(prefix) {
                sanitized = String(sanitized.dropFirst(prefix.count))
            }
        }

        return sanitized.trimmingCharacters(in: .whitespaces)
    }
}
