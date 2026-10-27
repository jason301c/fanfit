import Charts
import FanFitCore
import SwiftUI

@main
struct FanFitApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.state.enabled ? "fan.fill" : "fan")
                if let cpu = model.status?.temps.cpu, model.daemonOnline {
                    Text("\(Int(cpu.rounded()))°")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            positionPicker
            feedbackButtons
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            CurveChart()
            Divider()
            readings
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("FanFit").font(.headline)
            Spacer()
            Text(modeText).font(.caption).foregroundStyle(modeColor)
        }
    }

    private var modeText: String {
        guard model.daemonOnline, let s = model.status else { return "Daemon offline" }
        switch s.mode {
        case .curve: return "Following \(model.position.label.lowercased()) curve"
        case .apple: return "Apple (cool enough)"
        case .paused: return "Paused: Apple controls fans"
        case .safety: return "Safety: Apple controls fans"
        }
    }

    private var modeColor: Color {
        guard model.daemonOnline, let s = model.status else { return .red }
        switch s.mode {
        case .curve: return .orange
        case .apple, .paused: return .secondary
        case .safety: return .red
        }
    }

    private var positionPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: Binding(
                get: { model.positionIsAuto ? "auto" : model.position.rawValue },
                set: { model.setPosition($0 == "auto" ? nil : Position(rawValue: $0)) }
            )) {
                Text("Auto").tag("auto")
                Text("Desk").tag(Position.desk.rawValue)
                Text("Lap").tag(Position.lap.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.positionIsAuto
                 ? "\(model.position.label): \(model.externalDisplay ? "external display connected" : "no external display")"
                 : "\(model.position.label), picked by hand until the display changes")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var feedbackButtons: some View {
        HStack(spacing: 8) {
            Button { model.press(.tooHot) } label: {
                Label("Too hot", systemImage: "flame.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
            Button { model.press(.tooLoud) } label: {
                Label("Too loud", systemImage: "speaker.wave.3.fill").frame(maxWidth: .infinity)
            }
            .tint(.blue)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.state.enabled)
    }

    private var readings: some View {
        let s = model.status
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(s?.fans ?? [], id: \.index) { fan in
                row("Fan \(fan.index)", "\(Int(fan.actual).formatted()) RPM")
            }
            row("CPU", temp(s?.temps.cpu))
            row("GPU", temp(s?.temps.gpu))
            row("Palm rest", temp(s?.temps.palmRest))
            row("Battery", temp(s?.temps.battery))
            row("SSD", temp(s?.temps.ssd))
        }
        .font(.callout.monospacedDigit())
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func temp(_ v: Double?) -> String { v.map { String(format: "%.1f°C", $0) } ?? "–" }

    private var footer: some View {
        HStack {
            Toggle("FanFit on", isOn: Binding(get: { model.state.enabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small)
            Spacer()
            Menu("More") {
                Button("Undo last press") { model.undo() }.disabled(model.state.feedback.isEmpty)
                Button("Reset \(model.position.label.lowercased()) curve") { model.resetCurve() }
                Divider()
                Button("Quit FanFit") { NSApp.terminate(nil) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct CurveChart: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let p = model.position
        let curve = model.curve(for: p)
        let base = Curve.defaultCurve(for: p)
        let minRPM = model.fanMin
        Chart {
            ForEach(Array(zip(base.temps, base.rpms)), id: \.0) { t, rpm in
                LineMark(x: .value("°C", t), y: .value("RPM", rpm), series: .value("Curve", "Default"))
                    .foregroundStyle(.gray.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(Array(zip(curve.temps, curve.rpms)), id: \.0) { t, rpm in
                LineMark(x: .value("°C", t), y: .value("RPM", rpm), series: .value("Curve", "Yours"))
                    .foregroundStyle(.orange)
            }
            RuleMark(y: .value("Min", minRPM))
                .foregroundStyle(.gray.opacity(0.3))
                .annotation(position: .top, alignment: .leading) {
                    Text("below: Apple").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            ForEach(model.feedback(for: p)) { fb in
                PointMark(x: .value("°C", fb.temp), y: .value("RPM", fb.rpm))
                    .symbol(fb.kind == .tooHot ? .triangle : .circle)
                    .foregroundStyle(fb.kind == .tooHot ? .red : .blue)
                    .symbolSize(30)
            }
            if let s = model.status, model.daemonOnline {
                PointMark(x: .value("°C", s.controlTemp), y: .value("RPM", s.averageRPM))
                    .foregroundStyle(.primary)
                    .symbolSize(60)
            }
        }
        .chartXScale(domain: 40...95)
        .chartYScale(domain: 0...(model.fanMax.rounded(.up)))
        .chartXAxisLabel("°C")
        .chartYAxisLabel("RPM")
        .frame(height: 150)
    }
}
