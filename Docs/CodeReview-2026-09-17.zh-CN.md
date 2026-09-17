# AetherRoute 代码审查与下一步方案

审查日期：2026-09-17。基线：`d296a82`，包括审查时的工作区。开始时 `ContentView.swift` 有未提交修改；本次未修改任何产品源文件。审查覆盖 Swift 主应用、配置摘要/规则模拟、双引擎切换、授权与更新、Go 分发服务及测试入口；Rust 侧检查构建特性和入口边界，未逐行审计全部协议实现或第三方依赖。

结论：项目已有实质性的双引擎、配置加密、协议接入和测试基础。主要问题是新功能的语义正确性、生命周期边界、历史实现残留，以及测试/文档对完成程度的表达。不能把当前状态概括为“只有 UI”，也不能根据既有发布说明认定全部场景完成。

## 1. 审查发现（按处理优先级）

### R1 — P1：规则模拟器会给出错误且确定的路由结论

位置：`Sources/AetherRouteKit/ProfileConfigurationSummary.swift:274–406`；显示路径：`Sources/AetherRouteApp/FeatureViews.swift:312–365`。

- 使用 `kind.contains("IP")`，会先吞掉 `GEOIP`，后面的 GeoIP 分支不可达；也把 `SRC-IP-CIDR` 当作目标 IP 规则。
- GeoSite 采用 `host.contains(criteria)` 字符串匹配，没有查询 GeoSite 数据库。
- CIDR 计算只实现 IPv4；IPv6 只剩字符串相等兜底，没有计算网段。
- RULE-SET 等无法求值的规则被静默跳过，仍返回后面的 MATCH；真实执行可能在更早的规则就命中。
- 模拟没有足够信息处理源地址、端口、进程、规则集和 DNS 解析；结果的 target 是规则目标/策略组，并不等于最终出站节点。

已编译生产源文件复现：

| 输入和规则 | 当前结果 | 问题 |
| --- | --- | --- |
| `not-google.invalid`，`GEOSITE,google,DIRECT` 后接 MATCH/PROXY | DIRECT | 将包含 google 字符串误认为属于 Google GeoSite |
| `2001:db8::1`，`IP-CIDR6,2001:db8::/32,DIRECT` 后接 MATCH/PROXY | PROXY | IPv6 网段漏匹配 |
| 目标 `10.1.2.3`，`SRC-IP-CIDR,10.0.0.0/8,DIRECT` | DIRECT | 没有源 IP，却按目标 IP 判定源规则 |
| RULE-SET 后接 MATCH/PROXY | PROXY | 未加载规则集也宣称已判定路由 |

下一步：立即采用精确规则类型分派，并将结果改为“确定命中 / 无法判定 / 未命中”。遇到前置未知规则不能跳过后宣称确定。随后接入与 Rust 路由器一致的只读求值能力，或明确限定为基础域名/地址规则预览。补充 IPv6、源/目的区分、Geo 数据、RULE-SET 与真实核心对照测试。

### R2 — P2：模拟器只检查前 500 条规则，却把缺失结果展示为默认直连

位置：`Sources/AetherRouteKit/ProfileConfigurationSummary.swift:412,1119`；`Sources/AetherRouteApp/FeatureViews.swift:365,586`。

配置摘要明确为受限的 UI 投影，每节最多 500 项；模拟器却直接使用 `summary.rules`。构造 500 条不匹配域名规则和第 501 条 `MATCH,PROXY`，实际 `ruleCount=501`、`rules.count=500`、模拟结果 nil，界面据此提示默认直连。

下一步：展示模型和求值模型分离。短期如果摘要被截断，显示“规则不完整，无法判定”；完整求值不能依赖显示条数上限。验收覆盖 499/500/501 条和大配置。

### R3 — P2：引擎切换是先断后连，但状态显示和发布说明掩盖了中断

位置：`Sources/AetherRouteApp/TunnelManager.swift:1330,1381,1394,4900`；`Docs/ReleaseExceptions/1.0.12.md:12`。

代码先 `stopVPNTunnel()` 并等待旧引擎退出，然后才加载、配置、启动新引擎；切换期间 `updateState()` 对非 connected 状态直接返回，并保留旧连接起始时间。发布说明却写成先启动新引擎、确认就绪、再停止旧引擎。当前实现没有跨核心迁移既有 TCP/UDP 会话的机制。

影响：界面“持续已连接”不能证明流量连续；旧引擎退出到新引擎就绪之间存在捕获中断窗口。是否出现直连流量需要专门测试，本次没有实测泄漏。

下一步：先把产品承诺定义为“自动重连切换”，准确展示 switching 状态与中断；补齐切换失败、回滚、超时及切换中退出/断开测试。若要求不中断或 fail-closed，需要独立设计数据面与路由保证，不能仅通过隐藏状态实现。

### R4 — P1（仅 licensed 模式）：已授权的进程不会在凭据过期后正确撤销权限

位置：`Sources/AetherRouteApp/IndependentDistributionController.swift:129–157,276`；`Sources/AetherRouteApp/AppAutomationController.swift:240–255`；`Sources/AetherRouteKit/IndependentDistribution.swift:511–522`。

触发链：启动时凭据有效 → connectionAccess 设为 authorized → 运行期间 expiresAt 到期 → refreshLicense 的本地 verifiedEntitlement 抛出 expiredEntitlement → catch 只检查旧布尔权限，保留 authorized。没有定时到期撤销，也没有每次连接时按当前时间重算，后续刷新仍可能一直保留旧权限。

当前 project.yml 默认 free，所以这不是当前免费版的连通性缺陷，而是保留的收费能力上线阻断项。

下一步：区分到期/撤销等确定性错误与临时网络错误；每次连接前验证到期时间，并安排过期事件撤销权限。通过注入时钟测试运行中到期、睡眠跨过到期、离线到期和刷新失败。只有仍未过期的已验证凭据才可跨临时网络失败保留。

### R5 — P2：总测试入口在构建前依赖既有 framework，干净环境不可自洽

位置：`scripts/test.sh:41,168`；`Tests/ProxyLatencyMeasurement/run.sh:11–38`。

总入口先运行测速测试，后面才执行 xcodebuild；测速 runner 只查找既有 build 路径，没有 framework 会退出，有旧 framework 则可能测试旧实现。总入口的临时 DerivedData 路径也没有在这里传给 runner。

下一步：先构建当前提交的 framework，再传入唯一 `AETHERROUTE_PRODUCTS_DIR`；或像其他轻量 runner 一样从所需生产源码构建隔离模块。验收在无 build 缓存的 checkout 中运行，验证不会悄悄回退旧二进制。

### R6 — P2：网络切换验收可在未触发恢复逻辑时通过

位置：`scripts/test_vm_network_switch.sh:43–88`。

脚本添加/删除同一接口的 IP alias，然后检查公开 HTTP 204 和 PID；恢复日志只是打印，后面 `|| true`。没有强制断言本次触发了 physicalUplinkChanged/core reset，也未验证数据经过指定代理。即使相关监测逻辑失效、原链路始终可用，仍可能通过。

下一步：绑定本次测试时间、进程和会话，强制验证相应恢复事件；使用受控代理侧观测或仅代理可达的 canary。将 alias 变化、真实默认出口变化、断网恢复分别测试；添加 cleanup，失败时也移除 alias。

### R7 — P2：CI 没有持续覆盖主产品构建和 Swift 单元测试

位置：`.github/workflows/ci.yml:7–10`；`scripts/test_repository_ci.sh`。

当前仅 tag/manual 触发。CI 执行少量 Swift 独立 harness、脚本/元数据验证和 Go 测试；`xcodebuild -list` 只列工程，不构建 App，也未执行完整 Swift XCTest。不是“完全没有测试”，但普通提交缺少自动回归反馈，发布 CI 也不能代替产品构建/运行验证。

下一步：PR/主分支运行轻量静态和模型测试；macOS 必需任务构建 App + 两扩展并跑 Swift 单测；昂贵的协议互通/VM/长稳测试保留为按路径或发布门禁。测试报告绑定提交与产物摘要。

## 2. 未使用代码与保留能力

下表基于源码符号引用搜索和调用链核对；不是编译器全程序可达性证明。不将测试夹具、@main 入口和条件编译代码仅凭引用数少就判废弃。

| 项目 | 核对结果 | 建议 |
| --- | --- | --- |
| `AetherSurface`，AetherRouteVisualSystem.swift:646 | 仅定义，未发现实例化 | 删除或真正统一现有卡片组件 |
| `ProfileInspectionHeader`，FeatureViews.swift:1366 | 仅定义，未发现使用 | 删除旧页面残留 |
| `RustCoreLinkProbe.isLinked`，RustCoreLinkProbe.swift:1 | 未调用，注释所称的链接探针并未执行 | 删除，或接入专门的链接验收；现有 CoreBridge 仍有真实 ABI 调用，不能因此认定核心未链接 |
| `DiagnosticLogArchive`，DiagnosticLogArchive.swift:18 | 实现存在，但未发现 App 或测试调用；当前支持诊断是独立 AR1 路径 | 决定是否提供详细日志导出；如需要，增加明确入口、内容说明、大小/文件安全测试；否则删除 |
| `IndependentDistributionController.checkForUpdates` 与旧下载状态 | App 当前更新按钮调用 Sparkle，未发现旧 checkForUpdates 调用 | 以 Sparkle 为主收敛 App 层旧状态和入口 |
| `saveVerifiedUpdate`、`updateSymbol/updateTint/updateTitle/updateDetail`，IndependentDistributionView.swift:251,344 起 | 私有辅助代码未被实际视图调用；其内部 downloadUpdate 引用不代表可从 UI 到达 | 连同旧 App 更新链清理，避免误判为完整备用路径 |
| `ProtocolCatalog` | 生产 UI 无引用，但测试及协议矩阵验证仍使用 | 保留，标明它是验收目录，避免与 AetherNode 协议列表漂移 |
| `InMemoryProfileKeyStore`、`InMemoryDistributionCredentialStore` | 测试支持实现 | 不是产品废码；可考虑测试支持模块 |
| Go 分发服务、授权客户端、签名 manifest/download Kit | 当前 free 默认不启用授权，但存在测试和独立服务能力 | 属于可选产品方向，不应整块盲删；先决定是否保留 licensed 发行 |

Rust 搜索发现部分 TODO/unimplemented 位于 vendor、其他平台或未必启用的特性中。不能仅凭搜索命中断言当前 macOS 产物会触发；需要按实际 Cargo 特性和调用链确认。本次未将这些命中计为已确认产品缺陷。

## 3. 尚未完善或需要重新核实的部分

1. **规则模拟**：有界面与基础实现，但还不具备完整、可信的路由解释能力，优先修 R1/R2。
2. **连接切换**：自动停启和回滚已实现；连接连续性、切换中取消及流量保护需专门验收，不能从 UI 连续推出网络连续。
3. **详细日志导出**：底层归档实现未接入；现有隐私范围更小的 AR1 导出不等于详细日志归档。
4. **收费发行**：免费版未启用，授权过期存在缺陷；支付/客户系统及真实托管服务应作为独立里程碑，不应阻碍免费版精简。
5. **TUN 域名绕过**：当前路线只将 IPv4/IPv6 CIDR 转成 excluded routes，域名绕过不能按完整 TUN 能力宣传；应明确保持限制或另做 DNS 感知实现。
6. **真实睡眠与网络变化**：锁屏脚本自己明确说明不是睡眠测试；较新的 test_sleep_wake_recovery.sh 是 VM 冻结 + QA 事件，不是物理 macOS 睡眠通知证据。应保留这些测试，但增加真实设备合盖/唤醒验收。
7. **状态文档**：FeatureParity/Architecture 仍写“签名未完成”“连接中锁定引擎”；1.0.12 发布说明又声称已公证/VM 验收，并把切换顺序写反。应将“实现 / 本次验证 / 历史验证 / 尚缺证据”分开。本次未对线上发布包或公证结果重新验证。
8. **可维护性**：TunnelManager 约 6,254 行、ContentView 约 3,062 行、FeatureViews 约 1,819 行，承载过多职责。先补生命周期行为测试，再按连接会话、配置操作、观测、恢复拆分，避免一次性重写。

## 4. 本次验证及边界

- 通过：RuntimeEnvironment（模拟通知，不是真实睡眠）、ConnectionRows、ProxyPageNodeOrder、TrafficHistory，均从对应生产源码构建运行。
- 通过：Go `go test -race ./...` 两个 package；使用本机 Go 1.24.5（GOTOOLCHAIN=local），不是 go.mod 建议的 1.25.13 工具链，不能据此证明发布工具链结果。
- 规则复现：编译完整 ProfileConfigurationSummary.swift，通过 5 个诊断场景确认 R1/R2。复现文件在 `/private/tmp/aetherroute-review/main.swift`，二进制在同目录 route-review；临时目录可能被系统清理。
- 初次 Swift 执行受默认模块缓存写权限限制，指定临时缓存后通过；初次 Go 测试受回环监听限制，在允许本机测试监听的执行环境重跑后通过。它们不是产品测试失败。
- 未跑完整 xcodebuild/XCTest、Rust 全协议矩阵、安装/加载网络扩展、真实联网/休眠/长稳或发布验收；未更改系统网络。
- 本次只新增此审查报告；没有实施修复或清理。工作区是共享的，不能将审查期间外部变更归因于本次操作。

## 5. 下一步执行顺序与验收标准

| 顺序 | 工作包 | 完成标准 |
| --- | --- | --- |
| 1 | 修正规则模拟 R1/R2 | 复现场景正确；未知/截断不再声称确定；补入自动回归 |
| 2 | 修复连接切换语义和生命周期 | UI 如实展示切换；取消/退出不被后续异步启动覆盖；失败与回滚有可控测试；记录中断窗口 |
| 3 | 修复测试入口和 CI R5/R7 | 干净 checkout 可运行；明确绑定本次 framework；PR 有产品构建与 Swift 回归 |
| 4 | 处理 licensed 授权过期 R4 | 若保留收费方向，作为启用前 P1；注入时钟验证过期撤权；若仅免费发行则隔离为可选模块 |
| 5 | 小范围删除确认的 UI/更新残留 | 删除前后产品构建通过；Sparkle 菜单/设置更新入口正常；保留有调用的服务测试 |
| 6 | 加强网络与睡眠验收 R6 | 明确代理侧 canary、事件断言、失败恢复；区分 VM 模拟与物理实测，并关联产物摘要 |
| 7 | 同步文档并渐进拆分 TunnelManager | 每项能力有唯一状态和证据入口；按职责拆分且现有行为回归通过 |

建议先完成 1–3，再扩展新 UI 或新功能。收费方向如近期启用，将第 4 项前移，与第 1 项同优先级。
