import Foundation

/// 策略组节点展示排序策略
enum ProxyNodeSort: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case latency
    case name

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .default: AppLocalization.string("Default")
        case .latency: AppLocalization.string("By latency")
        case .name: AppLocalization.string("By name")
        }
    }
}

/// 策略组节点展示排序计算器
/// 保证在默认模式下严格保留配置原始声明顺序，彻底消除测速时卡片位置乱跳的体验问题。
enum ProxyPageNodeOrder {
    /// 计算单节点的延迟排序权重。
    /// 测出延迟的节点权重最小（排在最前），超时、测速中、未测速按序排后。
    static func rank(
        milliseconds: UInt32?,
        isTimedOut: Bool = false,
        isTesting: Bool = false
    ) -> Int {
        if let ms = milliseconds {
            return Int(ms)
        }
        if isTimedOut {
            return Int.max - 2
        }
        if isTesting {
            return Int.max - 1
        }
        return Int.max
    }

    /// 对节点列表进行排序。
    /// - Parameters:
    ///   - members: 原始节点名称列表
    ///   - sort: 排序策略
    ///   - latencyRank: 单节点延迟排序权重提供闭包
    /// - Returns: 排序后的节点列表
    static func sorted(
        members: [String],
        by sort: ProxyNodeSort,
        latencyRank: (String) -> Int = { _ in Int.max }
    ) -> [String] {
        switch sort {
        case .default:
            // 默认模式下绝对保留配置原始顺序，不发生任何位置重排与跳动
            return members
        case .latency:
            return members.sorted { lhs, rhs in
                latencyRank(lhs) < latencyRank(rhs)
            }
        case .name:
            return members.sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }
}
