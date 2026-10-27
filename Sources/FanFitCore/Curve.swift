import Foundation

/// A temperature → RPM curve, linear between knots. An RPM below the fans'
/// minimum means "let Apple's controller run the fans".
public struct Curve: Codable, Equatable, Sendable {
    public var temps: [Double]
    public var rpms: [Double]

    public init(temps: [Double], rpms: [Double]) {
        self.temps = temps
        self.rpms = rpms
    }

    public static let knotTemps: [Double] = stride(from: 40.0, through: 95.0, by: 5.0).map { $0 }

    public static func defaultCurve(for position: Position) -> Curve {
        switch position {
        // At the desk, stay quiet below 55°C and let the chip run warm.
        case .desk:
            return Curve(temps: knotTemps, rpms: [0, 0, 0, 0, 1800, 2400, 3000, 3700, 4400, 5100, 5800, 5800])
        // On the lap, the bottom case touches skin, so start at 48°C and ramp steadily.
        // Shaped on Jason's first presses: about 2,800 RPM wanted at 53°C, full speed by 75°C.
        case .lap:
            return Curve(temps: knotTemps, rpms: [0, 0, 2000, 2800, 3400, 4000, 4600, 5200, 5800, 5800, 5800, 5800])
        }
    }

    public func rpm(at t: Double) -> Double {
        guard let first = temps.first, let last = temps.last, temps.count == rpms.count else { return 0 }
        if t <= first { return rpms[0] }
        if t >= last { return rpms[rpms.count - 1] }
        let (i, a) = Curve.segment(temps, t)
        return rpms[i] * (1 - a) + rpms[i + 1] * a
    }

    /// Index of the segment holding `t`, and how far along it `t` sits (0...1).
    static func segment(_ temps: [Double], _ t: Double) -> (Int, Double) {
        var i = 0
        while i < temps.count - 2 && t > temps[i + 1] { i += 1 }
        let span = temps[i + 1] - temps[i]
        let a = span > 0 ? (t - temps[i]) / span : 0
        return (i, Swift.min(Swift.max(a, 0), 1))
    }

    /// Checks shape and bounds. The daemon rejects a control file that fails this.
    public var isValid: Bool {
        guard temps.count >= 2, temps.count == rpms.count, temps.count <= 64 else { return false }
        guard temps.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 150 }) else { return false }
        guard rpms.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000 }) else { return false }
        return zip(temps, temps.dropFirst()).allSatisfy { $0 < $1 }
    }
}

public struct Feedback: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case tooHot, tooLoud }
    public enum Bound: String, Codable, Sendable { case atLeast, atMost, exactly }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var position: Position
    /// Control temperature when the button was pressed.
    public var temp: Double
    /// Average fan RPM when the button was pressed.
    public var rpm: Double
    /// What the curve must do at `temp` to satisfy this press.
    public var bound: Bound
    public var target: Double

    public init(id: UUID = UUID(), date: Date, kind: Kind, position: Position, temp: Double, rpm: Double,
                bound: Bound, target: Double) {
        self.id = id
        self.date = date
        self.kind = kind
        self.position = position
        self.temp = temp
        self.rpm = rpm
        self.bound = bound
        self.target = target
    }

    /// Turns a button press into a constraint on the curve.
    /// - Parameters:
    ///   - appleRunning: true when Apple's controller, not the curve, set the current speed.
    ///   - fanMin: the fans' minimum RPM; anything lower turns the fans over to Apple.
    ///   - fanMax: the fans' maximum RPM.
    ///   - repeating: the previous press, if it was the same kind within a few seconds. The fans
    ///     have not caught up yet, so step on from its target instead of from the current speed.
    public static func make(kind: Kind, position: Position, temp: Double, rpm measured: Double, appleRunning: Bool,
                            fanMin: Double, fanMax: Double, repeating previous: Feedback? = nil,
                            date: Date = Date()) -> Feedback {
        let rpm = previous.map { kind == .tooHot ? Swift.max($0.target, measured) : Swift.min($0.target, measured) } ?? measured
        switch kind {
        case .tooHot:
            // Ask for a step you can hear the difference of: +30% or +700 RPM, at least 2,000.
            let want = Swift.min(Swift.max(rpm * 1.3, rpm + 700, 2000), fanMax)
            return Feedback(date: date, kind: kind, position: position, temp: temp, rpm: measured,
                            bound: .atLeast, target: want)
        case .tooLoud:
            let want = rpm * 0.8 - 100
            if appleRunning {
                // Apple's own speed is too loud: take over at a lower speed.
                return Feedback(date: date, kind: kind, position: position, temp: temp, rpm: measured,
                                bound: .exactly, target: Swift.max(want, fanMin + 50))
            }
            // Below the minimum the fans go back to Apple, which is quietest at these temps.
            return Feedback(date: date, kind: kind, position: position, temp: temp, rpm: measured,
                            bound: .atMost, target: want < fanMin ? 0 : want)
        }
    }
}

/// Fits a curve to the button presses for one position.
///
/// The fit moves the default curve as little as it can while meeting the
/// presses. It minimises
///   λ·|d|² + μ·|D¹d|² + Σ wₑ · violationₑ²
/// over non-decreasing curves between 0 and the fans' maximum, where d is the
/// change from the default and D¹ its first difference. The first difference
/// makes a press fade out over about sqrt(μ/λ) knots (7°C) on each side, so a
/// press at 53°C leaves 40°C and 80°C alone. A press counts only while the
/// curve breaks its bound, and newer presses weigh more.
///
/// The problem is convex, so projected gradient descent (FISTA) with the
/// exact projection (pool adjacent violators, then clamp) finds the optimum.
public enum CurveFitter {
    public static var halfLifeDays: Double = 21
    static let lambda = 1.0
    static let mu = 2.0
    /// How hard a fresh press pulls compared with the smoothing terms.
    static let pressWeight = 300.0
    static let iterations = 3000

    public static func fit(base: Curve, feedback: [Feedback], maxRPM: Double = 6000, now: Date = Date()) -> Curve {
        let n = base.temps.count
        guard n >= 3, !feedback.isEmpty else { return base }

        struct Press { let i: Int; let a: Double; let bound: Feedback.Bound; let target: Double; let w: Double }
        let presses = feedback.map { e -> Press in
            let ageDays = Swift.max(0, now.timeIntervalSince(e.date)) / 86_400
            let t = Swift.min(Swift.max(e.temp, base.temps[0]), base.temps[n - 1])
            let (i, a) = Curve.segment(base.temps, t)
            return Press(i: i, a: a, bound: e.bound, target: Swift.min(e.target, maxRPM),
                         w: pressWeight * pow(0.5, ageDays / halfLifeDays))
        }
        let b = base.rpms.map { Swift.min($0, maxRPM) }
        let lipschitz = 2 * (lambda + 4 * mu + presses.map(\.w).reduce(0, +))
        let step = 1 / lipschitz

        func gradient(_ x: [Double]) -> [Double] {
            let d = zip(x, b).map { $0 - $1 }
            var g = d.map { 2 * lambda * $0 }
            for k in 0..<(n - 1) {
                let diff = 2 * mu * (d[k + 1] - d[k])
                g[k] -= diff
                g[k + 1] += diff
            }
            for p in presses {
                let y = x[p.i] * (1 - p.a) + x[p.i + 1] * p.a
                let r: Double
                switch p.bound {
                case .atLeast: r = Swift.min(0, y - p.target)
                case .atMost: r = Swift.max(0, y - p.target)
                case .exactly: r = y - p.target
                }
                g[p.i] += 2 * p.w * r * (1 - p.a)
                g[p.i + 1] += 2 * p.w * r * p.a
            }
            return g
        }

        func project(_ y: [Double]) -> [Double] {
            isotonic(y).map { Swift.min(Swift.max($0, 0), maxRPM) }
        }

        // FISTA: gradient step from an extrapolated point, then project.
        var x = project(b)
        var z = x
        var t = 1.0
        for _ in 0..<iterations {
            let g = gradient(z)
            let next = project(zip(z, g).map { $0 - step * $1 })
            let tNext = (1 + (1 + 4 * t * t).squareRoot()) / 2
            z = zip(next, x).map { $0 + ((t - 1) / tNext) * ($0 - $1) }
            x = next
            t = tNext
        }
        return Curve(temps: base.temps, rpms: x.map { $0.rounded() })
    }

    /// Closest non-decreasing sequence in the least-squares sense (pool adjacent violators).
    static func isotonic(_ y: [Double]) -> [Double] {
        var blocks: [(sum: Double, count: Int)] = []
        for v in y {
            blocks.append((v, 1))
            while blocks.count > 1,
                  blocks[blocks.count - 2].sum / Double(blocks[blocks.count - 2].count)
                    > blocks[blocks.count - 1].sum / Double(blocks[blocks.count - 1].count) {
                let last = blocks.removeLast()
                blocks[blocks.count - 1].sum += last.sum
                blocks[blocks.count - 1].count += last.count
            }
        }
        return blocks.flatMap { [Double](repeating: $0.sum / Double($0.count), count: $0.count) }
    }
}
