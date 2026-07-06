import SwiftUI
import Charts

// 24h used% step chart shared by the app and the widgets.
struct HistoryChart: View {
    let series: [(Date, Double)]
    let color: Color

    var body: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Time", point.0), y: .value("Used", point.1))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(color.opacity(0.14))
                LineMark(x: .value("Time", point.0), y: .value("Used", point.1))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .foregroundStyle(color)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...100)
        .chartXScale(domain: Date().addingTimeInterval(-24 * 3600)...Date())
    }
}
