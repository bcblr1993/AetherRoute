import AetherRouteKit
import Combine
import Foundation

@MainActor
final class ProxyLatencyStore: ObservableObject {
    @Published var proxyLatencies: [String: ProxyLatencyState] = [:]
    @Published var proxyLatencyRequests: Set<String> = []
    @Published var memberLatencyRequests: Set<String> = []
    @Published var latencyMeasuredAt: [String: [String: Date]] = [:]
}
