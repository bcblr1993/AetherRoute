# AetherRoute 1.7.1 实施计划：透明代理跨网卡切换后自动恢复

2026-10-12 记录，同日实施（实施细节见第 5 节）。目标：透明代理模式下，切换到另一块网卡（Wi-Fi ↔ 有线 / USB 网卡 / 雷电扩展坞）或睡眠唤醒到另一块网卡后，**无需手动断开重连**即可在 10 秒内恢复上网。范围：A + B + C 三项一起做。

## 0. 故障证据（本机 1.6.0 / 2026101102，透明代理模式）

日志来源：`/usr/bin/log show --predicate 'subsystem == "com.aetherroute.desktop"'`，与 `configd` 的 `network changed:` 记录对照。

| 时间 | 系统网络变化 | 结果 |
|---|---|---|
| 10:03:07–10:03:10 | Wi-Fi `172.16.2.21` → iPhone 热点 `172.20.10.2`，**都在 en0** | `flowRecovery recovered(physicalLinkChanged, attempt 0)`，4 秒自动恢复 |
| 10:58:01–10:58:09 | 唤醒后改走有线 `10.8.5.253`，**en0 → en11** | wake、pathChanged ×5、appMessage ×7 次尝试全部 `attemptFailed`，且每次都在同一秒内失败（远短于 3 秒探测超时，说明是连接被立即拒绝）；App 侧 `automaticRouteHealth degraded action=continueMonitoring`；11:00:01 用户手动 stop/start 后立刻恢复 |

结论：同一块网卡上换网络能自愈，**换了网卡就只能手动重连**。

## 1. 根因（已核实代码）

1. **引擎在启动时就固定了出口网卡**：flow 引擎创建时调用 `init_net_config(None)`（`Core/Engine/clash-lib/src/embedded_flow.rs` 约 1201 行），把物理网卡写进进程级缓存 `DEFAULT_OUTBOUND_INTERFACE`。之后所有出站 socket 都经 `current_outbound_interface()` 用 `IP_BOUND_IF` 绑定到该网卡的编号（`proxy/utils/socket_helpers.rs`、`platform/apple.rs`；TUIC、ShadowQUIC 直接读这个缓存）。
2. **透明代理的软恢复不刷新它**：`TransparentProxyFlowRuntime.resetNetworkState()`（`Sources/AetherRouteTransparentProxySupport/TransparentProxyProviderRuntime.swift` 约 348 行）只做 `registry.cancelActiveSessions()`。不刷新出口网卡，不关闭引擎内到节点的复用连接，也不重置 DNS 客户端。
3. TUN 模式有完整重置：`clash_packet_reset_network_state_on_interface_v1` → `EmbeddedSelectorCommand::ResetNetworkState`（`clash-lib/src/lib.rs` 约 509 行），依次执行 `set_outbound_interface_index`、`statistics.close_all()`、`resolver.shutdown()`。但这条路径只对 packet 引擎注册，flow 引擎（`aether-flow-only`）没有对应入口。
4. 次要问题：
   - **App 不升级处理**：`TunnelManager+Telemetry.swift` 约 404 行，失败次数超过阈值后，`AutomaticRouteHealthRecoveryPolicy.exhaustionAction` 只有 `.continueMonitoring` 一种结果。当天 05:05–06:13，一个旧 App 实例连续失败 48→55 次，从未尝试重建。
   - **健康判定会误判为健康**：`NetworkRecoveryHealthPolicy.hasReceivedTraffic` 只要引擎总下行字节增加就判定健康，绕过代理的 DIRECT 流量也算在内，可能在代理链路仍断开时报告 `recovered`。

## 2. 方案

### A. 引擎与扩展：透明代理的真正网络重置（主修复）

- **引擎（`Core/Engine`）**：新增 `clash_flow_engine_reset_network_state_v1(engine, interface_index)`：
  1. `interface_index > 0` 时 `set_outbound_interface_index(index)`，否则 `refresh_outbound_interface()`；两种方式都会递增 `NETWORK_GENERATION`，使按代次缓存的传输层（QUIC / 多路复用连接池）失效；
  2. 关闭该引擎的全部上游连接（等同 `statistics.close_all()`）；
  3. `dns_resolver.shutdown()`，丢弃绑在旧网卡上的 DoH / DoT / UDP 客户端；
  4. 与 packet 路径一致：整体 2 秒超时，并用 reset gate 保证同一时间只有一次重置在执行；不得阻塞 selector / telemetry 命令。
- **FFI 新增检查清单**（见记忆"New FFI export checklist"）：`clashrs.h`、ABI 表、4 份符号列表、Flow ABI 数量门禁 26 → 27；核心提交后更新 `Config/ProtocolCoreEvidence.json` 的 `coreCommit`。
- **Swift**：`TransparentProxyFlowRuntime.resetNetworkState(interfaceIndex:)` 先 `cancelActiveSessions()`，再调用新的 FFI（有界等待，参照 `CoreBridge.resetNetworkState` 的 `resetQueue` + `outcome.wait` 模式）。
- **扩展**：`TransparentProxyProvider` 的恢复 `perform`：
  - attempt 0：用 `PhysicalUplinkDetector.currentPhysicalUplink` 的网卡编号执行完整重置；
  - attempt ≥ 1：仍以探测为主，但如果当前物理网卡编号与上次重置时不同，就再重置一次（网卡往往在唤醒后几秒才就绪）。

### B. 兜底：恢复用尽后原地重建引擎

- **扩展**：`NetworkRecoveryCoordinator` 发出 `exhausted` 时（或连续 N 次失败且网卡编号已变），由 `TransparentProxyProviderLifecycleController` 在进程内重建 flow 引擎，等同于用户手动 stop/start（重新解析上游节点地址、`init_net_config`、恢复节点选择），但不卸载系统扩展、不重新安装网络设置。重建期间新流量按现有的准入策略处理（拒绝或排队），不能让应用卡死。
- **App**：`AutomaticRouteHealthRecoveryPolicy.exhaustionAction` 新增 `.rebuildProvider`。条件：最近一次路径变化或唤醒后的 60 秒内，并且连接之前已就绪过。满足时通过 provider message 请求扩展重建；对每次路径变化只做一次，防止循环。不满足条件时保持现有的 `.continueMonitoring`（节点本身不可用不应触发重建）。
- 对 TUN 模式做同样的兜底评估：TUN 已有完整重置，只在恢复用尽时才重建。

### C. 收紧健康判定

- `hasReceivedTraffic` 改为只计**经代理出站**的下行字节（telemetry 中按出站链区分 DIRECT / 代理），或干脆取消，只认 URL 探测成功。
- 需要 telemetry 快照提供代理流量总数；如果 ART 快照没有这个字段，就用连接列表按链汇总，或者在 C 里直接去掉流量判定。

## 3. 测试

| 层级 | 内容 |
|---|---|
| 单元（Swift） | `NetworkRecoveryCoordinator`：网卡编号变化时 attempt ≥ 1 会再次重置；`exhausted` 触发重建回调；`AutomaticRouteHealthRecoveryPolicy` 的 `.rebuildProvider` 条件矩阵（宽限期内/外、是否就绪过、同一次路径变化不重复）；健康判定不再计入 DIRECT 流量。 |
| 单元（Rust） | flow 引擎重置：更新 `DEFAULT_OUTBOUND_INTERFACE`、递增 `NETWORK_GENERATION`、关闭连接、DNS shutdown；超时与并发重置被拒绝；`index == 0` 返回 `INVALID_STATE`。 |
| 回归套件 | `test_network_switch_gate.py`、`Tests/EngineReconnect/run.sh`、`Tests/RuntimeEnvironment/run.sh`、`./scripts/test.sh`。 |
| 协议互通 | `Core/Engine` 有改动，必须跑 `./scripts/test_protocol_interop_all.sh`，五项全部 PASS。 |
| 真机（Mac mini） | 透明代理模式：Wi-Fi → 有线、有线 → Wi-Fi、睡眠后唤醒到另一块网卡，各 3 次，均需在 10 秒内自动恢复（`curl` 经代理访问 generate_204 成功），日志里应出现 `recovered`，不应出现 `exhausted`。TUN 模式做同样的对照。注意：测试 TUN 时用局域网 IP 192.168.50.226 登录，切网卡时 SSH 可能会断，测试脚本要放在 Mac mini 本地后台运行。 |
| 发布门禁 | 按 AGENTS.md 全量执行（VM 矩阵或 Mac mini 替代、远程门禁、keep-alive、大上传、UI 性能门禁）。 |

## 4. 风险

- 重置会关闭所有到节点的连接，正在进行的下载会中断。只在物理链路确实变化时才重置（现有的 `pathSignature` 去重保留）。
- 进程内重建要和 `stopProxy`、选择节点、关闭连接等控制调用正确互斥，复用 lifecycle controller 现有的 `operationID` / `phase` 防重入机制。
- 新 FFI 必须同时进入 flow-only 与完整构建的符号列表，否则扩展加载时会出现缺少符号的错误。

## 5. 实施记录（2026-10-12）

与第 2 节相比的取舍：

| 项 | 实际做法 |
|---|---|
| A 引擎 | `EmbeddedFlowEngine::reset_network_state`：选网卡（`set_outbound_interface_index` 或 `refresh_outbound_interface`）→ `close_all` → DNS `shutdown`，整体 2 秒超时，并发请求返回 `InFlight`。FFI `clash_flow_engine_reset_network_state_v1`，状态码映射为 `BACKPRESSURE`（正在重置）、`INVALID_STATE`（网卡不可用）、`CANCELLED`（超时）。flow-only 构建的 `CoreComponents` 现在也保留 `dns_resolver`。ABI V8，Flow ABI 数量 27。 |
| A 扩展 | 照搬 TUN 扩展已有的写法：只有当物理网卡编号或地址签名与上次成功重置不同时才重置；重置成功前健康检查一律判为失败。网卡编号不被引擎识别时，改用 0 让引擎自己选。 |
| B 重建 | `TransparentProxyProviderLifecycleController.rebuildRuntime`：在准备队列上建好新引擎后再替换，网络设置和流量入口不动，旧引擎自行排空并关闭。触发时机：一轮恢复的第 3 次尝试（attempt 2，此前两次重置后的健康检查都失败）；用尽所有尝试时再重建一次。重建沿用启动时的配置，加上运行期间用户改过的节点选择和路由模式（`RuntimeRecipe`），所以不会回到启动时的选择。 |
| B App | `AutomaticRouteHealthRecoveryPolicy.exhaustionAction` 新增 `.reconnectProvider`。条件：连接曾就绪、不在唤醒宽限期内、距上次网络变化或唤醒不超过 180 秒、距上次自动重连至少 600 秒。只在有自动分组的配置上生效（这项检查本来就只看自动分组），是扩展自愈失败时的最后一道保险。 |
| C 健康判定 | 删除"下行字节增加即健康"的判定，TUN 与透明代理都改为只认经引擎的 URL 探测，并且**先探 GLOBAL、再探 DIRECT**，任一成功即健康。DIRECT 是兜底：网络变化坏掉的是引擎自身的出站路径（网卡绑定、DNS），DIRECT 正好测这条路径，而且不受节点好坏影响；只探 GLOBAL 的话，GLOBAL 节点本身挂了会让透明代理白白重建、让 TUN 长时间处于重连状态。GLOBAL 放在前面是因为节点通常正常，几百毫秒就有结果；而国内直连 google 要等满 3 秒超时（物理机上实测，DIRECT 在前时 TUN 的健康检查要 3.8 秒）。 |
| 发布门禁 | 新增 `scripts/test_interface_switch_recovery.sh`（在物理机上运行）与 `scripts/test_remote_interface_switch.sh`（在本机调用），写入 AGENTS.md 第 3 步，每次发布都必须跑。 |


## 6. 验证结果（2026-10-12）

| 项 | 结果 |
|---|---|
| 引擎单元测试 | 新增的 `network_reset_closes_upstream_connections_and_reports_failures` 与 FFI 状态映射测试通过；`embedded_flow` 模块 24/25、`clash-ffi` 43/43 通过。唯一失败的 `flow_only_engine_rejects_proxy_that_failed_handler_construction` 在未改动的代码上同样失败（是已有问题，与本次改动无关）。 |
| Swift 单元测试 | 产品构建零警告；AetherRouteTests 490、TransparentProxySupportTests 92、FlowCoreBridgeTests 24、Swift Testing 109，全部通过。 |
| 回归套件 | `test_network_switch_gate.py`、EngineReconnect、RuntimeEnvironment、临时文件清理检查全部通过。 |
| 协议互通 | 5 项全部 PASS（矩阵 48 个用例通过、26 次证书拒绝），日志在 `outputs/interop-20261012T034227Z`。 |
| 物理机基线（旧版 1.7.0，透明代理） | 关掉 Ethernet 后切到 en1，15 秒内**没有恢复，判定 FAIL**，复现了用户遇到的故障。如果只调整服务顺序（旧网卡仍在线），1.7.0 也能通过，所以门禁必须真正关掉旧网卡。 |
| 物理机（1.7.1 build 2026101202，透明代理） | 3 轮共 6 次切换全部恢复，每次 2 秒；日志显示每次路径变化后约 0.5 秒完成引擎重置，没有触发重建。 |
| 物理机（1.7.1 build 2026101202，TUN） | 3 轮共 6 次切换全部恢复，每次 1–2 秒。健康检查改为先探 DIRECT 的那一版（2026101201）实测要 2–7 秒，这也是后来改回先探 GLOBAL 的原因。 |
