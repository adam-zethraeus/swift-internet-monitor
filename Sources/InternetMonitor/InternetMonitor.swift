import AsyncAlgorithms
import Foundation
import Network
import SwiftUI
import os

// MARK: - Report types
public struct Sample: Sendable, Hashable, Identifiable {
  public enum NetworkProtocol: String, Sendable, Hashable {
    case udp
    case http
  }
  public let id = UUID()
  public let networkProtocol: NetworkProtocol
  public let target: String
  public let success: Bool
  public let latency: Duration?
}

public struct InternetStatusReport: Hashable, Sendable {
  public struct Jitter: Hashable, Sendable {
    public let value: Duration
    init(durations: [Duration]) {
      if durations.count < 2 {
        self.value = .zero
      } else {
        let secs = durations.map { $0 / Duration.seconds(1) }
        let jitter: Double =
          (zip(secs.dropFirst(), secs).map { abs($0 - $1) }.reduce(0.0, +))
          / Double(durations.count)
        self.value = Duration.seconds(jitter)
      }
    }
  }
  public struct Latency: Hashable, Sendable {
    init?(times: [Duration]) {
      guard !times.isEmpty else { return nil }
      let avg: Duration = times.reduce(Duration.seconds(0), +) / times.count
      let variance: TimeInterval = times.reduce(0.0) { partialResult, dur in
        let diff = (dur - avg)
        let diffInt = diff / Duration.seconds(1)
        return (partialResult + pow(diffInt, 2)) / Double(times.count)
      }
      self.mean = avg
      self.stddev = Duration.seconds(sqrt(variance))
    }
    public let mean: Duration
    public let stddev: Duration
  }
  public let timestamp: Date
  public let pathStatus: NWPath.Status
  public let dnsSamples: [Sample]
  public let httpSamples: [Sample]
  public let dnsJitter: Jitter
  public let httpJitter: Jitter

  public var all: Latency? {
    Latency(times: dnsSamples.compactMap { $0.latency } + httpSamples.compactMap { $0.latency })
  }

  public var dns: Latency? {
    Latency(times: dnsSamples.compactMap { $0.latency })
  }

  public var http: Latency? {
    Latency(times: httpSamples.compactMap { $0.latency })
  }

  public var rate: Double {
    guard pathStatus == .satisfied else { return 0 }
    let successes = dnsSamples.filter(\.success).count + httpSamples.filter(\.success).count
    let total = dnsSamples.count + httpSamples.count
    return total > 0 ? Double(successes) / Double(total) : 0
  }

  public enum NetworkQuality: String {
    case excellent
    case good
    case fair
    case poor
    case disconnected

    var color: Color {
      switch self {
      case .excellent:
        return .blue
      case .good:
        return .green
      case .fair:
        return .yellow
      case .poor:
        return .orange
      case .disconnected:
        return .red
      }
    }
  }

  public var quality: NetworkQuality {
    guard let all, pathStatus == .satisfied else { return .disconnected }
    switch (all.mean, httpJitter.value, rate) {
    case let (lat, jit, rate) where lat <= .seconds(0.04) && jit <= .seconds(0.01) && rate >= 0.995:
      return .excellent
    case let (lat, jit, rate) where lat <= .seconds(0.1) && jit <= .seconds(0.03) && rate >= 0.98:
      return .good
    case let (lat, jit, rate) where lat <= .seconds(0.25) && jit <= .seconds(0.06) && rate >= 0.9:
      return .fair
    default:
      return .poor
    }
  }
}

// MARK: - Monitor
@Observable
nonisolated public final class InternetStatusMonitor {
  public enum Default {
    public static let window: Int = 10
    public static let udpTargets: [String] = ["8.8.8.8", "1.1.1.1"]
    public static let httpTargets: [URL] = [
      URL(string: "https://clients3.google.com/generate_204")!,
      URL(string: "https://www.apple.com/library/test/success.html")!,
      URL(string: "https://connectivity-test.cloud.microsoft/")!,
    ]
  }

  private let udpTargets: [String]
  private let httpTargets: [URL]
  public var isRunning: Bool = false
  public private(set) var results: [ProbeResult] = []
  public private(set) var report: InternetStatusReport? {
    didSet {
      guard let report else { return }
      continuations.withLock { continuations in
        for cont in continuations.values {
          cont.continuation.yield(report)
        }
      }
    }
  }
  private let continuations: OSAllocatedUnfairLock<[UUID: IdentifiableContinuation]> = .init(
    initialState: [:])
  public var reports: AsyncStream<InternetStatusReport> {
    AsyncStream { cont in
      let identifiableCont = IdentifiableContinuation(continuation: cont)
      continuations.withLock { continuations in
        continuations[identifiableCont.id] = identifiableCont
      }
      cont.onTermination = { @Sendable [continuations] _ in
        continuations.withLock { continuations in
          continuations[identifiableCont.id] = nil
        }
      }
    }
  }

  struct IdentifiableContinuation: Sendable, Identifiable {
    let continuation: AsyncStream<InternetStatusReport>.Continuation
    let id = UUID()
  }
  private let interval: Duration
  private let tolerance: Duration
  private let window: Int

  public init(
    interval: Duration = .seconds(30),
    tolerance: Duration = .seconds(5),
    udpTargets: [String] = Default.udpTargets,
    httpTargets: [URL] = Default.httpTargets,
    window: Int = Default.window
  ) {
    self.interval = interval
    self.tolerance = tolerance
    self.udpTargets = udpTargets
    self.httpTargets = httpTargets
    self.window = window
  }
  public struct AlreadyRunningError: Error {
  }

  @MainActor private func receive(pathStatus: NWPath.Status) {
    report = InternetStatusReport(
      timestamp: Date(),
      pathStatus: pathStatus,
      dnsSamples: report?.dnsSamples ?? [],
      httpSamples: report?.httpSamples ?? [],
      dnsJitter: report?.dnsJitter ?? .init(durations: []),
      httpJitter: report?.httpJitter ?? .init(durations: [])
    )
  }

  @MainActor private func receive(probeResult: ProbeResult) {

    let lastTimestamp = self.report?.timestamp ?? .distantPast
    let timestamp = probeResult.timestamp > lastTimestamp ? probeResult.timestamp : lastTimestamp
    results.append(probeResult)
    results = results.suffix(window)

    let httpJitter = InternetStatusReport.Jitter(
      durations: results.flatMap { $0.httpSamples.compactMap(\.latency) })
    let dnsJitter = InternetStatusReport.Jitter(
      durations: results.flatMap { $0.dnsSamples.compactMap(\.latency) })

    report = InternetStatusReport(
      timestamp: timestamp,
      pathStatus: self.report?.pathStatus ?? .requiresConnection,
      dnsSamples: probeResult.dnsSamples,
      httpSamples: probeResult.httpSamples,
      dnsJitter: dnsJitter,
      httpJitter: httpJitter
    )
  }

  private enum Update {
    case path(NWPath.Status)
    case probe(ProbeResult)
  }

  /// Start the network monitor. Returning once it stops, or throw if
  /// this call can not start the monitor.
  @MainActor public func start() async throws(AlreadyRunningError) {
    guard !isRunning else { throw AlreadyRunningError() }
    isRunning = true
    defer {
      continuations.withLock {
        $0.forEach { $0.value.continuation.finish() }
        $0.removeAll()
      }
      isRunning = false
    }
    let udpTargets = self.udpTargets
    let httpTargets = self.httpTargets
    let interval = self.interval
    let tolerance = self.tolerance
    await withTaskGroup(of: Void.self) { group in
      let (updateStream, updateStreamCont) = AsyncStream.makeStream(
        of: Update.self, bufferingPolicy: .bufferingNewest(1))
      group.addTask {
        for await path in NWPathMonitor() {
          updateStreamCont.yield(.path(path.status))

        }
      }
      group.addTask {
        let timer = AsyncTimerSequence(
          interval: interval, tolerance: tolerance, clock: SuspendingClock()
        ).map { _ in () }
        let immediateTimer = chain([()].async, timer)
        for await _ in immediateTimer {
          let result = await Self.probe(udpTargets: udpTargets, httpTargets: httpTargets)
          updateStreamCont.yield(.probe(result))
        }
      }
      for await update in updateStream {
        switch update {
        case .path(let status):
          self.receive(pathStatus: status)
        case .probe(let result):
          self.receive(probeResult: result)
        }
      }
    }
  }
  static func udp(host: String) async -> Sample {
    let start = Date()
    let conn = NWConnection(host: NWEndpoint.Host(host), port: .init(rawValue: 53)!, using: .udp)
    return await withCheckedContinuation { cont in
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
          let latency = Duration.seconds(Date().timeIntervalSince(start))
          cont.resume(
            returning: Sample(networkProtocol: .udp, target: host, success: true, latency: latency)
          )
        case .failed, .cancelled:
          cont.resume(
            returning: Sample(networkProtocol: .udp, target: host, success: false, latency: nil))
        default: break
        }
      }
      conn.start(queue: .global())
    }
  }
  static func http(url: URL) async -> Sample {
    let start = Date()
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    return await withCheckedContinuation { cont in
      URLSession.shared.dataTask(with: request) { _, response, _ in
        let elapsed = Duration.seconds(Date().timeIntervalSince(start))
        let success =
          (response as? HTTPURLResponse)?.statusCode == 204
          || (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        cont.resume(
          returning: Sample(
            networkProtocol: .http, target: url.absoluteString, success: success,
            latency: success ? elapsed : nil))
      }.resume()
    }
  }

  public struct ProbeResult: Hashable, Sendable {
    let timestamp: Date
    let dnsSamples: [Sample]
    let httpSamples: [Sample]
  }

  private static func probe(udpTargets: [String], httpTargets: [URL]) async -> ProbeResult {
    return await withTaskGroup { group in
      let timestamp = Date()
      var dnsSamples: [Sample] = []
      var httpSamples: [Sample] = []
      // UDP checks
      for host in udpTargets {
        group.addTask {
          await Self.udp(host: host)
        }
      }
      // HTTP checks
      for url in httpTargets {
        group.addTask {
          await Self.http(url: url)
        }
      }
      for await sample in group {
        switch sample.networkProtocol {
        case .udp:
          dnsSamples.append(sample)
        case .http:
          httpSamples.append(sample)
        }
      }
      return .init(timestamp: timestamp, dnsSamples: dnsSamples, httpSamples: httpSamples)
    }
  }
}

public struct InternetStatusView: View {
  @State var monitor: InternetStatusMonitor
  @State var subscribe: Date?
  public init(interval: Duration = .seconds(15)) {
    self._monitor = State(wrappedValue: InternetStatusMonitor(interval: interval))
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
