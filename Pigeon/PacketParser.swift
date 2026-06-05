import Foundation

/// WHOOP packet parser
/// Based on Goose's protocol parsing (OpenWhoop reference)
class PacketParser {

    /// Parsed heart rate reading
    struct HeartRateReading {
        let timestamp: Date
        let bpm: Int
        let confidence: Double?
    }

    /// Parsed HRV reading (in milliseconds)
    struct HRVReading {
        let timestamp: Date
        let rmssd: Double  // Root Mean Square of Successive Differences
        let confidence: Double?
    }

    /// Parsed skin temperature reading (in Celsius)
    struct SkinTempReading {
        let timestamp: Date
        let temperature: Double
    }

    /// Parsed SpO2 reading (blood oxygen percentage)
    struct SpO2Reading {
        let timestamp: Date
        let percentage: Int
        let confidence: Double?
    }

    /// Packet type identifiers
    enum PacketType: UInt8 {
        case k24NormalHeartRate = 0x18  // K24 = 24 decimal = 0x18 hex
        case k10RawMotion = 0x0A        // K10 = 10 decimal = 0x0A hex
        case k17HRVOptical = 0x11       // K17 = 17 decimal = 0x11 hex
        case k21GroupedMotion = 0x15    // K21 = 21 decimal = 0x15 hex
        case k25SkinTemp = 0x19         // K25 = 25 decimal = 0x19 hex
        case k26SpO2 = 0x1A             // K26 = 26 decimal = 0x1A hex
        case unknown = 0xFF
    }

    /// Parse raw data into packet type
    static func identifyPacket(_ data: Data) -> PacketType {
        guard data.count > 0 else { return .unknown }

        // First byte typically indicates packet type in WHOOP protocol
        let firstByte = data[0]
        return PacketType(rawValue: firstByte) ?? .unknown
    }

    /// Parse K24 heart rate packet
    /// K24 format (simplified):
    /// - Byte 0: Packet type (0x18)
    /// - Byte 1-2: Timestamp offset
    /// - Byte 3: Heart rate (BPM)
    /// - Additional bytes: Extended data
    static func parseHeartRate(_ data: Data) -> HeartRateReading? {
        guard data.count >= 4 else { return nil }

        let packetType = data[0]
        guard packetType == PacketType.k24NormalHeartRate.rawValue else {
            return nil
        }

        // Extract BPM (byte 3 in simplified format)
        let bpm = Int(data[3])

        // Validate reasonable heart rate range
        guard bpm > 0 && bpm < 220 else {
            return nil
        }

        return HeartRateReading(
            timestamp: Date(),
            bpm: bpm,
            confidence: nil
        )
    }

    /// Parse K17 HRV packet
    /// K17 format:
    /// - Byte 0: Packet type (0x11)
    /// - Bytes 1-2: HRV value in milliseconds (little-endian)
    static func parseHRV(_ data: Data) -> HRVReading? {
        guard data.count >= 3 else { return nil }

        let packetType = data[0]
        guard packetType == PacketType.k17HRVOptical.rawValue else {
            return nil
        }

        // Extract HRV value (little-endian 16-bit)
        let rmssd = Double(UInt16(data[1]) | (UInt16(data[2]) << 8))

        // Validate reasonable HRV range (typically 10-200ms)
        guard rmssd >= 5 && rmssd <= 300 else {
            return nil
        }

        return HRVReading(
            timestamp: Date(),
            rmssd: rmssd,
            confidence: nil
        )
    }

    /// Parse K25 skin temperature packet
    /// K25 format:
    /// - Byte 0: Packet type (0x19)
    /// - Bytes 1-2: Temperature in 0.01°C units (little-endian)
    static func parseSkinTemp(_ data: Data) -> SkinTempReading? {
        guard data.count >= 3 else { return nil }

        let packetType = data[0]
        guard packetType == PacketType.k25SkinTemp.rawValue else {
            return nil
        }

        // Extract temperature (little-endian 16-bit, in 0.01°C units)
        let rawTemp = Int16(bitPattern: UInt16(data[1]) | (UInt16(data[2]) << 8))
        let tempCelsius = Double(rawTemp) / 100.0

        // Validate reasonable skin temp range (25-42°C)
        guard tempCelsius >= 25.0 && tempCelsius <= 42.0 else {
            return nil
        }

        return SkinTempReading(
            timestamp: Date(),
            temperature: tempCelsius
        )
    }

    /// Parse K26 SpO2 packet
    /// K26 format:
    /// - Byte 0: Packet type (0x1A)
    /// - Byte 1: SpO2 percentage
    static func parseSpO2(_ data: Data) -> SpO2Reading? {
        guard data.count >= 2 else { return nil }

        let packetType = data[0]
        guard packetType == PacketType.k26SpO2.rawValue else {
            return nil
        }

        let percentage = Int(data[1])

        // Validate reasonable SpO2 range (70-100%)
        guard percentage >= 70 && percentage <= 100 else {
            return nil
        }

        return SpO2Reading(
            timestamp: Date(),
            percentage: percentage,
            confidence: nil
        )
    }

    /// More sophisticated parsing: Look for heart rate patterns in data
    /// WHOOP sends HR in various packet structures, this tries multiple approaches
    static func extractHeartRate(_ data: Data) -> Int? {
        // Approach 1: Try K24 format
        if let reading = parseHeartRate(data) {
            return reading.bpm
        }

        // Approach 2: Scan for reasonable HR values in payload
        // Heart rate is typically 30-220 bpm
        for i in 0..<data.count {
            let value = Int(data[i])
            if value >= 40 && value <= 200 {
                // Found a plausible heart rate
                return value
            }
        }

        return nil
    }

    /// Extract HRV from packet
    static func extractHRV(_ data: Data) -> Double? {
        return parseHRV(data)?.rmssd
    }

    /// Extract skin temperature from packet
    static func extractSkinTemp(_ data: Data) -> Double? {
        return parseSkinTemp(data)?.temperature
    }

    /// Extract SpO2 from packet
    static func extractSpO2(_ data: Data) -> Int? {
        return parseSpO2(data)?.percentage
    }

    /// Get hex string for debugging
    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Decode packet for debugging
    static func debugDescription(_ data: Data) -> String {
        guard data.count > 0 else { return "Empty packet" }

        let type = identifyPacket(data)
        let hex = hexString(data)

        var description = "Type: \(type) | "

        if let hr = extractHeartRate(data) {
            description += "HR: \(hr) bpm | "
        }

        if let hrv = extractHRV(data) {
            description += "HRV: \(String(format: "%.1f", hrv)) ms | "
        }

        if let temp = extractSkinTemp(data) {
            description += "Temp: \(String(format: "%.1f", temp))°C | "
        }

        if let spo2 = extractSpO2(data) {
            description += "SpO2: \(spo2)% | "
        }

        description += "Bytes: \(data.count) | Hex: \(hex.prefix(20))..."

        return description
    }
}
