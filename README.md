# swift-internet-monitor

A lightweight Swift package that monitors internet connectivity using a combination of NWConnection (UDP), URLSession HTTP probes, and NWPathMonitor. Includes latency/jitter measurement support.

## Features
- Connectivity detection: Uses NWPathMonitor to observe when the network path becomes available or lost.
- HTTP availability check: Periodically sends HTTP GET requests to a configurable endpoint.
- Latency & jitter tracking: Measures response time per request and computes statistics.
- UDP ping: Low-overhead latency probe using NWConnection.
- Swift Package Manager: Easy to integrate into any Swift project.
- Modern Swift: Consume values via @Observable or async sequences.

## Installation

Via Swift Package Manager:

```swift
// package dependencies
dependencies: [
    .package(url: "https://github.com/adam-zethraeus/swift-internet-monitor.git", from: "0.1.0")
]

// product dependencies:
dependencies: [
  .product(name: "InternetMonitor", package: "swift-internet-monitor")
]
```

Then import InternetMonitor, and run via `.start()`

```swift
import InternetMonitor
import SwiftUI

struct InternetStatusView: View {
  @State var monitor: InternetStatusMonitor = .init(
    interval: .seconds(30),
    tolerance: .seconds(5),
    udpTargets: ["8.8.8.8"],
    httpTargets: [URL(string: "https://www.google.com")!],
    window: 30
  )
  var body: some View {
    VStack {
      Text("quality: " + (monitor.report?.quality.rawValue ?? "?"))
      Text("average latency: " + (monitor.report?.all?.mean?.formatted(
        Duration.UnitsFormatStyle(
          allowedUnits: [.milliseconds, .seconds], width: .narrow, maximumUnitCount: 2,
          zeroValueUnits: .hide, valueLength: nil,
          fractionalPart: .hide(rounded: .toNearestOrAwayFromZero))) ?? "")
      )
      Text("jitter: " + (monitor.report?.httpJitter.formatted(
        Duration.UnitsFormatStyle(
          allowedUnits: [.milliseconds, .seconds], width: .narrow, maximumUnitCount: 2,
          zeroValueUnits: .hide, valueLength: nil,
          fractionalPart: .hide(rounded: .toNearestOrAwayFromZero))) ?? "")
      )
    }
    .task {
      try? await monitor.start()
    }
  }
}
```

![internet monitor view](https://github.com/user-attachments/assets/67f6c6a6-fe08-47fa-97eb-cae52f337404)
