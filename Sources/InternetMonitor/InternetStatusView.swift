import AsyncAlgorithms
import Foundation
import Network
import SwiftUI

public struct InternetStatusView: View {
  @State var monitor: InternetMonitor
  @State var subscribe: Date?
  public init(interval: Duration = .seconds(15)) {
    self._monitor = State(wrappedValue: InternetMonitor(interval: interval))
  }
  @ViewBuilder
  var status: some View {
    switch monitor.report?.pathStatus {
    case .satisfied:
      Text("satisfied / \(monitor.report?.quality.rawValue ?? "?")").background(
        monitor.report?.quality.color ?? .gray
      ).background(in: Capsule())
    case .unsatisfied:
      Text("unsatisfied / \(monitor.report?.quality.rawValue ?? "?")").background(
        monitor.report?.quality.color ?? .gray
      ).background(in: Capsule())
    case .requiresConnection:
      Text("requires connection / \(monitor.report?.quality.rawValue ?? "?")").background(
        monitor.report?.quality.color ?? .gray
      ).background(in: Capsule())
    case .none:
      Text("unknown / \(monitor.report?.quality.rawValue ?? "?")").background(
        monitor.report?.quality.color ?? .gray
      ).background(in: Capsule())
    @unknown default:
      Text("unknown / \(monitor.report?.quality.rawValue ?? "?")").background(
        monitor.report?.quality.color ?? .gray
      ).background(in: Capsule())
    }
  }

  let fmt = { (duration: Duration?) in
    guard let duration else { return "-" }
    let style = Duration.UnitsFormatStyle(
      allowedUnits: [.milliseconds, .seconds], width: .narrow, maximumUnitCount: 2,
      zeroValueUnits: .hide, valueLength: nil,
      fractionalPart: .hide(rounded: .toNearestOrAwayFromZero))
    return duration.formatted(style)
  }

  @ViewBuilder
  func reportRow(name: String, _ dur: Duration?) -> some View {
    Text(
      "\(name): \(fmt(dur))"
    )
    .contentTransition(.numericText(value: (dur ?? .zero) / Duration.seconds(1)))
  }

  public var body: some View {
    List {
      if let report = monitor.report {
        Section("Connection:") {
          status

        }
        Section("Rate:") {
          Text("\(report.rate, format: .percent.precision(.fractionLength(0)))")
            .contentTransition(.numericText(value: report.rate))
        }
        Section("DNS:") {
          reportRow(name: "avg", report.dns?.mean)
          reportRow(name: "stddev", report.dns?.stddev)
        }
        Section("HTTP:") {
          reportRow(name: "avg", report.http?.mean)
          reportRow(name: "stddev", report.http?.stddev)
        }
        Section("HTTP details") {
          ForEach(report.httpSamples.sorted(by: { $0.target < $1.target })) { sample in
            reportRow(name: sample.target, sample.latency).strikethrough(!sample.success)
          }
        }
        Section("Jitter") {
          reportRow(name: "dns", report.dnsJitter.value)
          reportRow(name: "http", report.httpJitter.value)
        }
      } else {
        ContentUnavailableView(
          label: {
            Label("No report yet", systemImage: "hourglass")
              .labelStyle(.iconOnly)
              .rotationEffect(.degrees(0 + (subscribe != nil ? 360 : 0)))
          },
          description: {
            Text("Waiting for initial report")
          }
        )
        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: subscribe)
      }
    }
    .frame(maxWidth: .infinity)
    .containerRelativeFrame(.horizontal, count: 5, span: 3, spacing: 0, alignment: .center)
    .font(.headline.monospaced())
    .animation(.easeInOut, value: monitor.report)
    .task {
      subscribe = .now
      try? await monitor.start()
      subscribe = nil
    }
  }
}

#Preview("InternetStatusView") {
  InternetStatusView(interval: .seconds(5))
}
