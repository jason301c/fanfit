import CSMC
import FanFitCore
import Foundation

/// Reads and writes the fan and temperature keys of this Mac's SMC.
final class SMC {
    struct TempKey {
        let key: String
        let group: WritableKeyPath<Temperatures, Double?>
    }

    let fanCount: Int
    /// "F%dmd" on M5 and later, "F%dMd" before.
    private let modeKeyFormat: String
    /// M1 to M4 need Ftst=1 before a fan accepts manual mode; M5 has no Ftst.
    private let hasFtst: Bool
    private(set) var tempKeys: [TempKey] = []

    init() throws {
        let r = smc_open()
        guard r == 0 else { throw NSError(domain: "fanfitd", code: Int(r), userInfo: [NSLocalizedDescriptionKey: "Cannot open AppleSMC (\(r))"]) }
        fanCount = Int(SMC.raw("FNum")?.bytes.first ?? 0)
        modeKeyFormat = SMC.raw("F0md") != nil ? "F%dmd" : "F%dMd"
        hasFtst = SMC.raw("Ftst") != nil
        tempKeys = SMC.discoverTempKeys()
    }

    // MARK: Reading

    struct Raw {
        let type: String
        let bytes: [UInt8]
    }

    static func raw(_ key: String) -> Raw? {
        var v = smc_value_t()
        guard smc_read(key, &v) == 0 else { return nil }
        let bytes = withUnsafeBytes(of: v.bytes) { Array($0.prefix(Int(v.size))) }
        let type = withUnsafeBytes(of: v.type) { String(decoding: $0.prefix(4), as: UTF8.self) }
        return Raw(type: type, bytes: bytes)
    }

    static func float(_ key: String) -> Double? {
        guard let r = raw(key) else { return nil }
        if r.type == "flt ", r.bytes.count == 4 {
            return Double(r.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        }
        // ioft: little-endian 16.16 fixed point in the first 4 of 8 bytes.
        if r.type == "ioft", r.bytes.count == 8 {
            let fixed = r.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Double(fixed) / 65536
        }
        return nil
    }

    /// Finds every temperature key in the groups FanFit shows, by name prefix.
    static func discoverTempKeys() -> [TempKey] {
        func group(for key: String) -> WritableKeyPath<Temperatures, Double?>? {
            if key == "Ts0P" { return \.palmRest }
            if key == "TAOL" { return \.ambient }
            if key.hasPrefix("Tp") || key == "TCMb" || key == "TCHP" { return \.cpu }
            if key.hasPrefix("Tg") { return \.gpu }
            if key.hasPrefix("Tm") { return \.memory }
            if key.hasPrefix("TH0") { return \.ssd }
            if key.hasPrefix("TB"), key.hasSuffix("T") { return \.battery }
            return nil
        }
        var keys: [TempKey] = []
        let count = smc_key_count()
        var name = [CChar](repeating: 0, count: 5)
        for i in 0..<count {
            guard smc_key_at(i, &name) == 0 else { continue }
            let key = String(cString: name)
            guard key.hasPrefix("T"), let g = group(for: key), let t = float(key), t > 5, t < 130 else { continue }
            keys.append(TempKey(key: key, group: g))
        }
        return keys
    }

    func temperatures() -> Temperatures {
        var t = Temperatures()
        for k in tempKeys {
            guard let v = SMC.float(k.key), v > 5, v < 130 else { continue }
            t[keyPath: k.group] = Swift.max(t[keyPath: k.group] ?? 0, v)
        }
        return t
    }

    func fans() -> [FanReading] {
        (0..<fanCount).map { i in
            FanReading(
                index: i,
                actual: SMC.float("F\(i)Ac") ?? 0,
                target: SMC.float("F\(i)Tg") ?? 0,
                min: SMC.float("F\(i)Mn") ?? 0,
                max: SMC.float("F\(i)Mx") ?? 0,
                manual: SMC.raw(modeKey(i))?.bytes.first == 1
            )
        }
    }

    // MARK: Writing (root only)

    private func modeKey(_ fan: Int) -> String { String(format: modeKeyFormat, fan) }

    @discardableResult
    private func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { smc_write(key, $0.baseAddress, UInt32($0.count)) == 0 }
    }

    private func floatBytes(_ v: Double) -> [UInt8] {
        withUnsafeBytes(of: Float(v)) { Array($0) }
    }

    /// Puts a fan in manual mode. The SMC sometimes refuses for a moment, so retry for up to 2 s.
    func takeManual(_ fan: Int) -> Bool {
        if hasFtst { write("Ftst", [1]) }
        for _ in 0..<20 {
            if write(modeKey(fan), [1]) { return true }
            usleep(100_000)
        }
        return false
    }

    func setTarget(_ fan: Int, rpm: Double) -> Bool {
        write("F\(fan)Tg", floatBytes(rpm))
    }

    /// Hands every fan back to Apple's controller.
    func resetToApple() {
        for i in 0..<fanCount {
            write(modeKey(i), [0])
            write("F\(i)Tg", floatBytes(0))
        }
        if hasFtst { write("Ftst", [0]) }
    }
}
