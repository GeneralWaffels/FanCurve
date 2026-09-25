import SwiftUI
import SMCKit

/// Draggable fan curve. Drag a point to move it, double-click empty space to add one,
/// right-click a point to delete it. RPMs below the fan minimum mean "fans off (macOS idle)".
struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    var currentTemp: Double?
    var fanMin: Double
    var fanMax: Double

    private let tempRange = 30.0...100.0
    private var rpmRange: ClosedRange<Double> { 0...(ceil(fanMax / 1000) * 1000) }
    private let inset = EdgeInsets(top: 12, leading: 52, bottom: 30, trailing: 16)

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: inset.leading, y: inset.top,
                              width: geo.size.width - inset.leading - inset.trailing,
                              height: geo.size.height - inset.top - inset.bottom)
            let sorted = points.indices.sorted { points[$0].temp < points[$1].temp }

            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    // grid + axis labels
                    for t in stride(from: tempRange.lowerBound, through: tempRange.upperBound, by: 10) {
                        let x = pos(CurvePoint(temp: t, rpm: 0), plot).x
                        ctx.stroke(Path { $0.move(to: .init(x: x, y: plot.minY)); $0.addLine(to: .init(x: x, y: plot.maxY)) }, with: .color(.secondary.opacity(0.15)))
                        ctx.draw(Text("\(Int(t))°").font(.caption2).foregroundColor(.secondary), at: .init(x: x, y: plot.maxY + 12))
                    }
                    for r in stride(from: rpmRange.lowerBound, through: rpmRange.upperBound, by: 1000) {
                        let y = pos(CurvePoint(temp: 0, rpm: r), plot).y
                        ctx.stroke(Path { $0.move(to: .init(x: plot.minX, y: y)); $0.addLine(to: .init(x: plot.maxX, y: y)) }, with: .color(.secondary.opacity(0.15)))
                        ctx.draw(Text("\(Int(r))").font(.caption2).foregroundColor(.secondary), at: .init(x: plot.minX - 24, y: y))
                    }

                    // shaded "fans off" band below minimum RPM
                    let minY = pos(CurvePoint(temp: 0, rpm: fanMin), plot).y
                    ctx.fill(Path(CGRect(x: plot.minX, y: minY, width: plot.width, height: plot.maxY - minY)), with: .color(.blue.opacity(0.06)))
                    ctx.draw(Text("below \(Int(fanMin)) rpm = fans off (macOS idle)").font(.caption2).foregroundColor(.blue.opacity(0.7)),
                             at: .init(x: plot.maxX - 4, y: plot.maxY - 8), anchor: .trailing)

                    // curve (extended flat to both edges)
                    if let f = sorted.first.map({ points[$0] }), let l = sorted.last.map({ points[$0] }) {
                        var path = Path()
                        path.move(to: pos(CurvePoint(temp: tempRange.lowerBound, rpm: f.rpm), plot))
                        for i in sorted { path.addLine(to: pos(points[i], plot)) }
                        path.addLine(to: pos(CurvePoint(temp: tempRange.upperBound, rpm: l.rpm), plot))
                        ctx.stroke(path, with: .color(.accentColor), style: .init(lineWidth: 2.5, lineJoin: .round))
                    }

                    // live temperature marker
                    if let t = currentTemp {
                        let cfg = { var c = FanConfig(); c.points = points; return c }()
                        let p = pos(CurvePoint(temp: min(max(t, tempRange.lowerBound), tempRange.upperBound), rpm: cfg.rpm(at: t)), plot)
                        ctx.stroke(Path { $0.move(to: .init(x: p.x, y: plot.minY)); $0.addLine(to: .init(x: p.x, y: plot.maxY)) },
                                   with: .color(.orange), style: .init(lineWidth: 1, dash: [4, 3]))
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.orange))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { loc in
                    points.append(value(at: loc, plot))
                }

                ForEach(points.indices, id: \.self) { i in
                    let p = pos(points[i], plot)
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(p)
                        .help("\(Int(points[i].temp))°C → \(points[i].rpm < fanMin ? "off" : "\(Int(points[i].rpm)) rpm")")
                        .gesture(DragGesture().onChanged { g in
                            guard points.indices.contains(i) else { return }
                            points[i] = value(at: g.location, plot)
                        })
                        .contextMenu {
                            Button("Delete point") { if points.count > 2 { points.remove(at: i) } }
                                .disabled(points.count <= 2)
                        }
                }
            }
        }
    }

    private func pos(_ p: CurvePoint, _ r: CGRect) -> CGPoint {
        let x = (p.temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)
        let y = (p.rpm - rpmRange.lowerBound) / (rpmRange.upperBound - rpmRange.lowerBound)
        return CGPoint(x: r.minX + x * r.width, y: r.maxY - y * r.height)
    }

    private func value(at loc: CGPoint, _ r: CGRect) -> CurvePoint {
        let x = min(max((loc.x - r.minX) / r.width, 0), 1)
        let y = min(max((r.maxY - loc.y) / r.height, 0), 1)
        let temp = (tempRange.lowerBound + x * (tempRange.upperBound - tempRange.lowerBound)).rounded()
        var rpm = (rpmRange.lowerBound + y * (rpmRange.upperBound - rpmRange.lowerBound)) / 50
        rpm = rpm.rounded() * 50
        return CurvePoint(temp: temp, rpm: min(rpm, fanMax))
    }
}
