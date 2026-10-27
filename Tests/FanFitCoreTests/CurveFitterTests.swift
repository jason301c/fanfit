import XCTest
@testable import FanFitCore

final class CurveFitterTests: XCTestCase {
    let now = Date()
    let base = Curve.defaultCurve(for: .desk)

    func fb(_ kind: Feedback.Kind, _ temp: Double, _ rpm: Double, apple: Bool = false, daysAgo: Double = 0) -> Feedback {
        Feedback.make(kind: kind, position: .desk, temp: temp, rpm: rpm, appleRunning: apple,
                      fanMin: 1350, fanMax: 5800, date: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func testNoFeedbackKeepsDefault() {
        XCTAssertEqual(CurveFitter.fit(base: base, feedback: [], now: now), base)
    }

    func testTooHotRaisesCurveAroundThatTemperature() {
        let press = fb(.tooHot, 72, base.rpm(at: 72))
        let fitted = CurveFitter.fit(base: base, feedback: [press], maxRPM: 5800, now: now)
        XCTAssertGreaterThanOrEqual(fitted.rpm(at: 72), press.target * 0.95)
        // Neighbours move too, but less, and far temperatures barely move.
        XCTAssertGreaterThan(fitted.rpm(at: 65), base.rpm(at: 65))
        XCTAssertLessThan(abs(fitted.rpm(at: 40) - base.rpm(at: 40)), 150)
        XCTAssertEqual(fitted.rpms, CurveFitter.isotonic(fitted.rpms))
    }

    func testTooLoudLowersCurve() {
        let press = fb(.tooLoud, 80, base.rpm(at: 80))
        let fitted = CurveFitter.fit(base: base, feedback: [press], maxRPM: 5800, now: now)
        XCTAssertLessThanOrEqual(fitted.rpm(at: 80), press.target * 1.05)
    }

    func testSatisfiedPressChangesNothing() {
        // "Too hot" at 1,000 RPM wants ≥ 2,000, which the default already gives at 85°C.
        let press = fb(.tooHot, 85, 1000)
        XCTAssertEqual(CurveFitter.fit(base: base, feedback: [press], now: now), base)
    }

    func testLoudWhileAppleRunsTakesOverBelowAppleSpeed() {
        let press = fb(.tooLoud, 55, 2500, apple: true)
        XCTAssertEqual(press.bound, .exactly)
        let fitted = CurveFitter.fit(base: base, feedback: [press], maxRPM: 5800, now: now)
        // Quieter than Apple was, but still above the minimum so FanFit holds the fans.
        XCTAssertLessThan(fitted.rpm(at: 55), press.rpm)
        XCTAssertGreaterThan(fitted.rpm(at: 55), 1350)
    }

    func testNewerPressWinsAConflict() {
        let old = fb(.tooHot, 70, 2400, daysAgo: 30)
        let new = fb(.tooLoud, 70, 2400)
        let fitted = CurveFitter.fit(base: base, feedback: [old, new], maxRPM: 5800, now: now)
        XCTAssertLessThan(fitted.rpm(at: 70), 2400)
    }

    /// Jason's first nine lap presses (2026-10-27). The old fitter turned them into a flat
    /// 3,681 RPM shelf from 40°C up; the fit must stay local and keep the ramp.
    func testRealLapPressesKeepTheRamp() {
        let presses: [(Double, Double, Double)] = [
            (53.5, 1404, 2104), (54.1, 2283, 2983), (52.8, 2719, 3535), (52.9, 2830, 3679),
            (76.1, 4943, 5777), (76.1, 4943, 5777), (76.1, 4943, 5777), (74.8, 4782, 5777), (72.9, 5100, 5777),
        ]
        let feedback = presses.map {
            Feedback(date: now, kind: .tooHot, position: .lap, temp: $0.0, rpm: $0.1, bound: .atLeast, target: $0.2)
        }
        let lap = Curve.defaultCurve(for: .lap)
        let fitted = CurveFitter.fit(base: lap, feedback: feedback, maxRPM: 5777, now: now)
        XCTAssertLessThan(fitted.rpm(at: 40), 1350, "40°C stays with Apple")
        XCTAssertLessThan(fitted.rpm(at: 45), 1350, "45°C stays with Apple")
        XCTAssertGreaterThan(fitted.rpm(at: 70) - fitted.rpm(at: 55), 1000, "the curve still ramps from 55 to 70°C")
        for f in feedback { XCTAssertGreaterThan(fitted.rpm(at: f.temp), f.target * 0.95) }
    }

    func testPressFadesWithDistance() {
        let press = fb(.tooHot, 70, 3000)
        let fitted = CurveFitter.fit(base: base, feedback: [press], maxRPM: 5800, now: now)
        let lift = { (t: Double) in fitted.rpm(at: t) - self.base.rpm(at: t) }
        XCTAssertGreaterThan(lift(70), 900 * 0.97)
        XCTAssertLessThan(lift(55), lift(65))
        XCTAssertLessThan(lift(50), 100)
    }

    func testQuickRepeatStepsOnFromLastTarget() {
        let first = fb(.tooHot, 60, 2000)
        let second = Feedback.make(kind: .tooHot, position: .desk, temp: 60, rpm: 2050, appleRunning: false,
                                   fanMin: 1350, fanMax: 5800, repeating: first)
        XCTAssertGreaterThan(second.target, first.target + 600)
    }

    func testIsotonic() {
        XCTAssertEqual(CurveFitter.isotonic([1, 3, 2, 4]), [1, 2.5, 2.5, 4])
    }
}
