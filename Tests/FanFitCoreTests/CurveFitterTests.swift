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

    func testIsotonic() {
        XCTAssertEqual(CurveFitter.isotonic([1, 3, 2, 4]), [1, 2.5, 2.5, 4])
    }
}
