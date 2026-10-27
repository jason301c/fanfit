import FanFitCore
import Foundation

// fanfitd: runs as root under launchd. Once a second it reads the sensors,
// looks up the curve the app chose, sets the fans and writes status.json.
//
//   fanfitd           run the control loop (root)
//   fanfitd --probe   print fans and temperatures once (any user)
//   fanfitd --reset   hand the fans back to Apple and exit (root)

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(s)")
}

let smc: SMC
do {
    smc = try SMC()
} catch {
    log("fatal: \(error.localizedDescription)")
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
if args.contains("--probe") {
    let status = Status(time: Date(), mode: .apple, position: nil, controlTemp: 0, curveRPM: 0,
                        fans: smc.fans(), temps: smc.temperatures(), error: nil)
    print(String(decoding: try JSONEncoder.fanfit.encode(status), as: UTF8.self))
    print("temperature keys: \(smc.tempKeys.map(\.key).joined(separator: " "))")
    exit(0)
}
if args.contains("--reset") {
    smc.resetToApple()
    print("Fans handed back to Apple.")
    exit(0)
}
guard getuid() == 0 else {
    log("fatal: the control loop needs root; run it through launchd")
    exit(1)
}

/// Above this, Apple's controller takes over until the chip cools to `safetyRelease`.
let safetyLimit = 98.0
let safetyRelease = 90.0
/// Most RPM the fans may change per second. Slow down-ramps keep the noise from pumping.
let rampUp = 500.0
let rampDown = 150.0
/// Once following the curve, keep following it until it falls this far below the fans' minimum.
let handBackMargin = 250.0

final class Controller {
    var control: Control?
    var controlModified: Date?
    var smoothed: Double?
    var commanded: Double?
    var lastWritten: [Int: Double] = [:]
    var mode: FanMode = .paused
    var ownsFans = false

    func loadControl() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.control.path)
        let modified = attrs?[.modificationDate] as? Date
        guard modified != controlModified else { return }
        controlModified = modified
        guard let data = try? Data(contentsOf: Paths.control),
              let c = try? JSONDecoder.fanfit.decode(Control.self, from: data), c.curve.isValid else {
            if control != nil { log("control file missing or invalid; handing fans to Apple") }
            control = nil
            return
        }
        control = c
        log("control: \(c.enabled ? "on" : "paused"), \(c.position.rawValue), rpms \(c.curve.rpms.map { Int($0) })")
    }

    func tick() {
        loadControl()
        let temps = smc.temperatures()
        var fans = smc.fans()
        let peak = Swift.max(temps.cpu ?? 0, temps.gpu ?? 0)
        smoothed = smoothed.map { $0 + 0.3 * (peak - $0) } ?? peak
        let t = smoothed ?? peak

        let fanMin = fans.map(\.min).min() ?? 0
        let curveRPM = control?.curve.rpm(at: t) ?? 0
        var error: String?

        let next: FanMode
        if peak >= safetyLimit || (mode == .safety && peak > safetyRelease) {
            next = .safety
        } else if control?.enabled != true {
            next = .paused
        } else if curveRPM < fanMin - (mode == .curve ? handBackMargin : 0) {
            // The margin stops the fans flipping between FanFit and Apple where the curve crosses the minimum.
            next = .apple
        } else {
            next = .curve
        }
        if next != mode { log("mode \(mode.rawValue) -> \(next.rawValue) at \(String(format: "%.1f", t))°C") }

        if next == .curve {
            // Start from the speed Apple left the fans at, so the hand-over is silent.
            let current = commanded ?? fans.map(\.actual).reduce(0, +) / Double(Swift.max(fans.count, 1))
            let step = Swift.min(Swift.max(curveRPM - current, -rampDown), rampUp)
            let rpm = current + step
            commanded = rpm
            for fan in fans {
                let target = Swift.min(Swift.max(rpm, fan.min), fan.max)
                if !fan.manual {
                    if smc.takeManual(fan.index) { lastWritten[fan.index] = nil } else { error = "fan \(fan.index) refused manual mode" }
                }
                if abs((lastWritten[fan.index] ?? -1000) - target) >= 20 || !fan.manual {
                    if smc.setTarget(fan.index, rpm: target) { lastWritten[fan.index] = target } else { error = "fan \(fan.index) refused target" }
                }
            }
            ownsFans = true
        } else {
            commanded = nil
            if ownsFans || fans.contains(where: \.manual) {
                smc.resetToApple()
                lastWritten = [:]
                ownsFans = false
                fans = smc.fans()
            }
        }
        mode = next

        let status = Status(time: Date(), mode: mode, position: control?.position, controlTemp: t,
                            curveRPM: curveRPM, fans: fans, temps: temps, error: error)
        if let data = try? JSONEncoder.fanfit.encode(status) {
            try? data.write(to: Paths.status, options: .atomic)
        }
    }
}

try? FileManager.default.createDirectory(at: Paths.status.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o755])

// Clear whatever another fan tool left behind, then hand back on every way out.
smc.resetToApple()
atexit { smc.resetToApple() }
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        log("signal \(sig); handing fans to Apple")
        smc.resetToApple()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

log("started: \(smc.fanCount) fans, \(smc.tempKeys.count) temperature keys")
let controller = Controller()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: 1.0)
timer.setEventHandler { controller.tick() }
timer.resume()
dispatchMain()
