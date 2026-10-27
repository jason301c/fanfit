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
        // At the desk, stay quiet and let the chip run warm.
        case .desk:
            return Curve(temps: knotTemps, rpms: [0, 0, 0, 0, 0, 1800, 2400, 3000, 3800, 4600, 5300, 5800])
        // On the lap, the bottom case touches skin, so start earlier.
        case .lap:
            return Curve(temps: knotTemps, rpms: [0, 0, 0, 1500, 2000, 2600, 3200, 3900, 4600, 5200, 5800, 5800])
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
    public static func make(kind: Kind, position: Position, temp: Double, rpm: Double, appleRunning: Bool,
                            fanMin: Double, fanMax: Double, date: Date = Date()) -> Feedback {
        switch kind {
        case .tooHot:
            // Ask for a step you can hear the difference of: +30% or +700 RPM, at least 2,000.
            let want = Swift.min(Swift.max(rpm * 1.3, rpm + 700, 2000), fanMax)
            return Feedback(date: date, kind: kind, position: position, temp: temp, rpm: rpm,
                            bound: .atLeast, target: want)
        case .tooLoud:
            let want = rpm * 0.8 - 100
            if appleRunning {
                // Apple's own speed is too loud: take over at a lower speed.
                return Feedback(date: date, kind: kind, position: position, temp: temp, rpm: rpm,
                                bound: .exactly, target: Swift.max(want, fanMin + 50))
            }
            // Below the minimum the fans go back to Apple, which is quietest at these temps.
            return Feedback(date: date, kind: kind, position: position, temp: temp, rpm: rpm,
                            bound: .atMost, target: want < fanMin ? 0 : want)
        }
    }

    func isViolated(by curve: Curve) -> Bool {
        let y = curve.rpm(at: temp)
        switch bound {
        case .atLeast: return y < target - 1
        case .atMost: return y > target + 1
        case .exactly: return abs(y - target) > 1
        }
    }
}

/// Fits a curve to the button presses for one position.
///
/// The fit moves the default curve as little as it can while meeting the
/// presses: it minimises
///   λ·|d|² + μ·|D²d|² + Σ wₑ (curve(Tₑ) − targetₑ)²
/// where d is the change from the default and D² the second difference, so a
/// press also lifts or lowers the neighbouring temperatures smoothly. Each
/// press counts only while its bound is broken (an active set that only
/// grows), newer presses weigh more, and the result is made non-decreasing.
public enum CurveFitter {
    public static var halfLifeDays: Double = 21
    static let lambda = 0.02
    static let mu = 0.1
    /// How hard a fresh press pulls compared with the smoothing terms.
    static let pressWeight = 10.0

    public static func fit(base: Curve, feedback: [Feedback], maxRPM: Double = 6000, now: Date = Date()) -> Curve {
        let n = base.temps.count
        guard n >= 3, !feedback.isEmpty else { return base }

        let weights = feedback.map { e -> Double in
            let ageDays = Swift.max(0, now.timeIntervalSince(e.date)) / 86_400
            return pressWeight * pow(0.5, ageDays / halfLifeDays)
        }

        var active = Set<Int>()
        var curve = base
        for _ in 0...feedback.count {
            let newlyViolated = feedback.indices.filter { !active.contains($0) && feedback[$0].isViolated(by: curve) }
            if newlyViolated.isEmpty { break }
            active.formUnion(newlyViolated)
            curve = solve(base: base, feedback: feedback, weights: weights, active: active)
        }

        var rpms = isotonic(curve.rpms)
        rpms = rpms.map { Swift.min(Swift.max($0, 0), maxRPM).rounded() }
        return Curve(temps: base.temps, rpms: rpms)
    }

    static func solve(base: Curve, feedback: [Feedback], weights: [Double], active: Set<Int>) -> Curve {
        let n = base.temps.count
        var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var b = [Double](repeating: 0, count: n)

        for i in 0..<n { A[i][i] += lambda }
        for k in 1..<(n - 1) {
            let coeffs = [(k - 1, 1.0), (k, -2.0), (k + 1, 1.0)]
            for (i, ci) in coeffs { for (j, cj) in coeffs { A[i][j] += mu * ci * cj } }
        }
        for e in active {
            let fb = feedback[e]
            let t = Swift.min(Swift.max(fb.temp, base.temps[0]), base.temps[n - 1])
            let (i, a) = Curve.segment(base.temps, t)
            let coeffs = [(i, 1 - a), (i + 1, a)]
            let residual = fb.target - base.rpm(at: t)
            for (p, cp) in coeffs {
                b[p] += weights[e] * cp * residual
                for (q, cq) in coeffs { A[p][q] += weights[e] * cp * cq }
            }
        }

        let d = gaussianSolve(A, b) ?? [Double](repeating: 0, count: n)
        return Curve(temps: base.temps, rpms: zip(base.rpms, d).map { $0 + $1 })
    }

    static func gaussianSolve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = A
        var v = b
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else {
                return nil
            }
            m.swapAt(col, pivot)
            v.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let f = m[row][col] / m[col][col]
                if f == 0 { continue }
                for k in col..<n { m[row][k] -= f * m[col][k] }
                v[row] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = v[row]
            for k in (row + 1)..<n { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x
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
