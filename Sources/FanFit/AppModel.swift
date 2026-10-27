import AppKit
import FanFitCore
import Foundation

/// What the app keeps between launches, in ~/Library/Application Support/FanFit/state.json.
struct StoredState: Codable {
    var enabled = true
    var feedback: [Feedback] = []
    /// A position picked by hand. It lasts until the external display is plugged in or out.
    var override: Position?
    var overrideDisplayState: Bool?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: Status?
    @Published private(set) var externalDisplay = false
    @Published private(set) var state = StoredState()
    @Published private(set) var message: String?

    private let stateURL: URL
    private var timer: Timer?
    private var lastControl: Data?
    private var messageClear: DispatchWorkItem?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FanFit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder.fanfit.decode(StoredState.self, from: data) {
            state = s
        }

        externalDisplay = Self.hasExternalDisplay()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readStatus() }
        }
        readStatus()
        writeControl()
    }

    // MARK: Position

    var position: Position { state.override ?? (externalDisplay ? .desk : .lap) }
    var positionIsAuto: Bool { state.override == nil }

    func setPosition(_ p: Position?) {
        state.override = p
        state.overrideDisplayState = p == nil ? nil : externalDisplay
        save()
    }

    private func screensChanged() {
        let now = Self.hasExternalDisplay()
        guard now != externalDisplay else { return }
        externalDisplay = now
        // Plugging in or out is a fresh signal; drop the hand-picked position.
        if state.override != nil, state.overrideDisplayState != now {
            state.override = nil
            state.overrideDisplayState = nil
        }
        save()
    }

    static func hasExternalDisplay() -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
    }

    // MARK: Curves

    var fanMax: Double { status?.fans.map(\.max).max() ?? 6000 }
    var fanMin: Double { status?.fans.map(\.min).min() ?? 1300 }

    private var curveCache: [Position: (key: [UUID], maxRPM: Double, day: Int, curve: Curve)] = [:]

    /// The fitted curve. Cached because the panel asks for it on every redraw; a fit takes a few milliseconds.
    func curve(for p: Position) -> Curve {
        let presses = state.feedback.filter { $0.position == p }
        let key = presses.map(\.id)
        // Presses fade by age, so refit at least once a day.
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        if let c = curveCache[p], c.key == key, c.maxRPM == fanMax, c.day == day { return c.curve }
        let fitted = CurveFitter.fit(base: .defaultCurve(for: p), feedback: presses, maxRPM: fanMax)
        curveCache[p] = (key, fanMax, day, fitted)
        return fitted
    }

    func feedback(for p: Position) -> [Feedback] { state.feedback.filter { $0.position == p } }

    // MARK: Actions

    func press(_ kind: Feedback.Kind) {
        guard let status, Date().timeIntervalSince(status.time) < 10 else {
            show("The fan daemon isn't running, so there's nothing to adjust.")
            return
        }
        let p = position
        let t = status.controlTemp
        let rpm = status.averageRPM
        if kind == .tooHot, rpm >= fanMax - 100 {
            show("Fans are already at full speed.")
            return
        }
        if kind == .tooLoud, status.mode == .apple || status.mode == .paused, rpm < fanMin + 100 {
            show("Fans are already as slow as they go.")
            return
        }
        // Presses a few seconds apart are one stronger press: replace the last one and step on from it.
        var previous: Feedback?
        if let last = state.feedback.last, last.kind == kind, last.position == p,
           Date().timeIntervalSince(last.date) < 15 {
            previous = state.feedback.removeLast()
        }
        let before = curve(for: p).rpm(at: t)
        let fb = Feedback.make(kind: kind, position: p, temp: t, rpm: rpm, appleRunning: status.mode != .curve,
                               fanMin: fanMin, fanMax: fanMax, repeating: previous)
        state.feedback.append(fb)
        // Keep the newest 60 presses per position; older ones have decayed anyway.
        for pos in Position.allCases {
            let mine = state.feedback.filter { $0.position == pos }
            if mine.count > 60 { state.feedback.removeAll { f in mine.prefix(mine.count - 60).contains(f) } }
        }
        let after = curve(for: p).rpm(at: t)
        save()
        show("\(p.label) curve at \(Int(t.rounded()))°C: \(rpmText(before)) → \(rpmText(after))" + conflictNote(fb))
    }

    func undo() {
        guard let last = state.feedback.last else { return }
        state.feedback.removeLast()
        save()
        show("Removed the last \(last.kind == .tooHot ? "too hot" : "too loud") press.")
    }

    func resetCurve() {
        let p = position
        state.feedback.removeAll { $0.position == p }
        save()
        show("\(p.label) curve is back to the default.")
    }

    func setEnabled(_ on: Bool) {
        state.enabled = on
        save()
    }

    private func conflictNote(_ fb: Feedback) -> String {
        // A recent opposite press near the same temperature means you've hit the noise/heat limit.
        let recent = state.feedback.dropLast().filter {
            $0.position == fb.position && $0.kind != fb.kind && abs($0.temp - fb.temp) < 4
                && fb.date.timeIntervalSince($0.date) < 3 * 86_400
        }
        return recent.isEmpty ? "" : "\nYou also said the opposite near this temperature recently, so the curve splits the difference."
    }

    private func rpmText(_ rpm: Double) -> String {
        rpm < fanMin ? "Apple" : "\(Int(rpm.rounded()).formatted()) RPM"
    }

    private func show(_ text: String) {
        message = text
        messageClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.message = nil }
        messageClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    // MARK: Files

    private func save() {
        if let data = try? JSONEncoder.fanfit.encode(state) { try? data.write(to: stateURL, options: .atomic) }
        writeControl()
        objectWillChange.send()
    }

    private func writeControl() {
        let control = Control(enabled: state.enabled, position: position, curve: curve(for: position))
        guard let data = try? JSONEncoder.fanfit.encode(control), data != lastControl else { return }
        let dir = Paths.control.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? data.write(to: Paths.control, options: .atomic)) != nil { lastControl = data }
    }

    private func readStatus() {
        guard let data = try? Data(contentsOf: Paths.status),
              let s = try? JSONDecoder.fanfit.decode(Status.self, from: data) else {
            status = nil
            return
        }
        status = s
        // Curves depend on the fans' max, which arrives with the first status.
        writeControl()
    }

    var daemonOnline: Bool {
        guard let status else { return false }
        return Date().timeIntervalSince(status.time) < 10
    }
}
