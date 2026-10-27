import Foundation

/// Files the app and the daemon share. The daemon only writes `status`; the
/// app only writes `control`.
public enum Paths {
    /// Written by the root daemon once a second. World-readable.
    public static let status = URL(fileURLWithPath: "/var/run/fanfit/status.json")
    /// Written by the menu bar app. The daemon reads it and validates every value.
    public static let control = URL(fileURLWithPath: "/Users/Shared/FanFit/control.json")
}

public enum Position: String, Codable, CaseIterable, Sendable {
    case desk, lap

    public var label: String { self == .desk ? "Desk" : "Lap" }
}

/// What the daemon is doing with the fans right now.
public enum FanMode: String, Codable, Sendable {
    /// The daemon holds the fans in manual mode and follows the curve.
    case curve
    /// The curve is below the fans' minimum here, so Apple's controller runs them.
    case apple
    /// The app turned FanFit off; Apple's controller runs the fans.
    case paused
    /// A sensor passed the safety limit; Apple's controller runs the fans.
    case safety
}

public struct FanReading: Codable, Sendable {
    public var index: Int
    public var actual: Double
    public var target: Double
    public var min: Double
    public var max: Double
    public var manual: Bool

    public init(index: Int, actual: Double, target: Double, min: Double, max: Double, manual: Bool) {
        self.index = index
        self.actual = actual
        self.target = target
        self.min = min
        self.max = max
        self.manual = manual
    }
}

/// Temperatures in °C. Each group is the hottest sensor in that group.
public struct Temperatures: Codable, Sendable {
    public var cpu: Double?
    public var gpu: Double?
    public var memory: Double?
    public var ssd: Double?
    public var battery: Double?
    public var palmRest: Double?
    public var ambient: Double?

    public init() {}
}

public struct Status: Codable, Sendable {
    public var time: Date
    public var mode: FanMode
    public var position: Position?
    /// Smoothed max of CPU and GPU; the input to the curve.
    public var controlTemp: Double
    /// What the curve asked for, before rate limiting. 0 means "leave it to Apple".
    public var curveRPM: Double
    public var fans: [FanReading]
    public var temps: Temperatures
    public var error: String?

    public init(time: Date, mode: FanMode, position: Position?, controlTemp: Double, curveRPM: Double,
                fans: [FanReading], temps: Temperatures, error: String?) {
        self.time = time
        self.mode = mode
        self.position = position
        self.controlTemp = controlTemp
        self.curveRPM = curveRPM
        self.fans = fans
        self.temps = temps
        self.error = error
    }

    public var averageRPM: Double {
        fans.isEmpty ? 0 : fans.map(\.actual).reduce(0, +) / Double(fans.count)
    }
}

public struct Control: Codable, Sendable {
    public var enabled: Bool
    public var position: Position
    public var curve: Curve

    public init(enabled: Bool, position: Position, curve: Curve) {
        self.enabled = enabled
        self.position = position
        self.curve = curve
    }
}

public extension JSONEncoder {
    static var fanfit: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

public extension JSONDecoder {
    static var fanfit: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
