# AetherRoute 1.7.2 实施计划：控制面防卡死看门狗与失联自愈、UDP 重置日志降级与运维日志落盘

2026-10-13 记录与实施。目标：针对控制面跨进程失联、UDP 短连接对端重置产生告警噪点、宿主关键诊断信息未持久化及流量统计字段兼容性进行全方位加固与闭环修复，确保客户端与系统扩展在各种异常网络波动与长时间高负载下均能自愈且零干扰。

## 1. 问题分析与修复方案

### P0：控制面跨进程心跳看门狗与失联自愈
- **根因**：
  - 宿主 App 与 Network Extension 之间通过 IPC（`sendProviderMessage`）进行通信。在极端阻塞、系统扩展内部工作队列耗尽或 XPC 超时无响应时，`TunnelManager` 仅单纯捕获超时错误并累加失败计数，但原策略在连续失联达到上限时仅返回 `.continueMonitoring`，无法触发实质性自愈动作，导致客户端 UI 遥测卡死或呈现假死状态。
  - 透明代理扩展端在处理 `handleAppMessage` 时，缺少针对单次消息处理的有界看门狗保护。若下游处理挂起，消息处理回调将无法完成。
- **修复措施**：
  1. `ProxySelectionStore.swift`：在 `AutomaticRouteHealthRecoveryPolicy` 中新增 `providerUnresponsiveThreshold = 3` 与 `providerUnresponsiveCooldown = 300`，修改 `exhaustionAction` 支持入参 `consecutiveProviderUnresponsiveCount`，连续无应答达到阈值且非冷却期时返回 `.reconnectProvider`。
  2. `TunnelManager.swift` / `TunnelManager+ProxySelection.swift`：新增 `consecutiveProviderUnresponsiveCount` 计数器。在收到有效响应时清零，在 `providerReplyMissing` 或 `providerMessageTimedOut` 时递增；状态重置时清零。
  3. `TunnelManager+Telemetry.swift`：新增 `checkUnresponsiveProviderRecovery()`，在遥测轮询异常捕获块及自动路由健康刷新中介入，触发 `.reconnectProvider` 重新激活 Provider 自愈。
  4. `TransparentProxyProvider.swift`：在 `handleAppMessage` 中加入 15 秒 `watchdogTimer`（全局 utility 队列），超时记录 failure 并返回 `.unavailable`，防止扩展端挂起。

### P1-a：UDP 对端重置（code=2）日志降级
- **根因**：
  - 在 macOS Network Extension 透明代理模式下，DNS 查询、QUIC 及实时通信等大量短连接 UDP 交互在对端主动关闭或重置时，系统会抛出 `NEAppProxyErrorDomain` code 2（`NEAppProxyFlowError.peerReset`）。
  - 原实现将其记录为 `failure` 级别，导致日志与 Console 产生海量高警级别误报（日志污染），掩盖真正致命错误。
- **修复措施**：
  1. `NetworkExtensionFlowAccess.swift`：精准识别 `nsError.domain == NEAppProxyErrorDomain && nsError.code == NEAppProxyFlowError.peerReset.rawValue`，降级为 `verbose` 级别，不再作为 `failure`。
  2. `TransparentProxyFlowSession.swift`：UDP 与 TCP 握手失败为 `FlowIOError.closed` 时统一降为 `verbose`。

### P1-b：宿主 App 关键运维诊断日志落盘
- **根因**：
  - 宿主 App 的关键运维事件（如控制面超时自愈、启停请求、自愈重连触发等）此前仅输出到 Unified Logging（`os.Logger`），未写入 `DiagnosticLogCenter.current.log` 的 2MB 轮转日志（`app.log`），导致通过“导出诊断包”无法获取宿主 App 的关键自愈上下文。
- **修复措施**：
  1. `TunnelManager.swift`：引入 `diagnosticLog = DiagnosticLogCenter.current.log(category: AppLog.Category.appRuntime)`。
  2. 在关键自愈与重连分界点调用 `Self.diagnosticLog.failure(...)` / `lifecycle(...)`，确保宿主关键自愈行为被完整持久化到 App Group 轮转日志中。

### P2-a：流量统计字段兼容性补全
- **根因**：
  - `DiagnosticAggregator.swift` 中的 `DiagnosticCounter` 缺少针对 upstream/client 维度的独立计数项，未来扩展或数据对齐时存在不完备隐患。
- **修复措施**：
  1. 补充 `.bytesUpstream(Int)` 与 `.bytesClient(Int)` 分支，保证数据链路模型完整性。

## 2. 验证矩阵

| 验证项 | 验证内容与目标 | 结果 |
|---|---|---|
| 本地单元与回归测试 | `ProxySelectionStoreTests` 新增看门狗自愈测试；运行 `test_network_switch_gate.py`、`EngineReconnect`、`RuntimeEnvironment`、`test.sh` | 全部 PASS |
| 12 协议真实互通门禁 | `./scripts/fetch_interop_tools.sh` 与 `./scripts/test_protocol_interop_all.sh`（48 用例、26 证书拦截） | 全部 PASS |
| Tart 虚拟机 6 维矩阵 | `macos27` 跑 6 维引擎与路由组合，含空闲复用、SNI 恢复、2 MiB 上传 | 全部 PASS |
| Mac mini 远程真机门禁 | `chenxu@100.64.0.3` 物理真机多场景自动化测试门禁 | 全部 PASS |
| Mac mini 切换网卡自动恢复 | `test_remote_interface_switch.sh`（en0 ↔ en1 来回切换 3 轮各 6 次），15 秒内自动恢复 | 全部 PASS |
| Mac mini UI 性能与内存门禁 | `test_ui_performance_gate.sh` 展示档与 large 档各切页 5 分钟 | 全部 PASS |
