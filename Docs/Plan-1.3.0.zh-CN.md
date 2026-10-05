# AetherRoute 1.3.0 实施方案：看得清、管得住

> 状态：方案待确认（2026-10-05）。确认前不开始编码。
> 范围：仅 macOS；iOS 同步另行安排。

## 1. 背景与目标

与主流客户端（Clash Verge Rev、Mihomo Party、Surge、Stash 等）相比，AetherRoute 在系统集成、协议验证、安全与稳定性上已经持平或领先，但在**日常可见性与可控性**上有三处用户每天都能感受到的差距：

| 差距 | 用户场景 | 主流客户端 |
|---|---|---|
| 连接页看不到是哪个 App 发起的连接 | "为什么这个 App 不走代理 / 为什么这么多流量" | Verge、Surge 显示进程名与图标 |
| 没有"按 App 分流"的界面 | "让微信始终直连、让 Claude 始终走代理" | Surge、Stash 的核心功能 |
| 不显示订阅的已用流量和到期时间 | "我的机场还剩多少流量、什么时候到期" | 几乎所有 Clash 客户端都显示 |

1.3.0 的目标是补齐这三项，并把"按 App 分流"做成 AetherRoute 的特色：macOS 透明代理本身就能可靠地识别每条连接的来源 App，这是基于 TUN 的客户端不容易做好的。

**非目标**（本版不做）：MITM 解密、请求改写、脚本、开放网页控制面板（风险高、与"安全省心"的定位冲突）；uTLS 浏览器指纹（单独评估，计划 1.4）；iOS 同步。

## 2. 现状调研结论

| 项目 | 现状 | 依据 |
|---|---|---|
| 透明代理的来源 App | 系统为每条流提供 `NEFlowMetaData.sourceAppSigningIdentifier`（非可选）与 `sourceAppAuditToken`（可能为空），目前只用于识别 AetherRoute 自身的流量 | `Sources/AetherRouteTransparentProxySupport/TransparentProxySelfIdentityGuard.swift` |
| 透明代理的进程规则 | 引擎对透明代理流量**主动拒绝** `PROCESS-NAME` / `PROCESS-PATH` 规则（配置加载报错） | `Core/Engine/clash-lib/src/embedded_flow.rs`（"PROCESS-NAME and PROCESS-PATH rules are unavailable for Apple transparent flows"） |
| 流创建接口 | `clash_flow_tcp_create` / `clash_flow_udp_create` 只传源/目标地址，没有来源 App 信息 | `Core/Engine/clash-ffi/src/flow_ffi.rs` |
| TUN 的进程识别 | 引擎的 `process` 特性（`sock2proc`，按套接字表反查进程）在两份发布核心的编译配置中都**关闭**；主程序与两个扩展均启用 App Sandbox，能否读取其他进程信息未验证 | `clash-lib/Cargo.toml`（`process = ["dep:sock2proc"]`），`scripts/build_core.sh`、`scripts/build_direct_core.sh`（`--no-default-features`），`Config/*.entitlements` |
| 连接遥测 | 二进制格式 v1，每条连接含传输层、目标、端口、上下行、开始时间、规则、规则载荷、代理链，**没有来源 App 字段** | `flow_ffi.rs` `encode_telemetry_snapshot`，`Sources/AetherRouteKit/NetworkTelemetry.swift` |
| 自定义规则 | 支持 DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / IP-CIDR / GEOIP 等，优先级最高，策略为直连 / 拒绝 / 指定代理 | `Sources/AetherRouteKit/CustomRule.swift` |
| 订阅响应头 | 下载订阅时已保存全部 HTTP 响应头，但没有解析 `subscription-userinfo` | `Sources/AetherRouteKit/ProfileSubscription.swift`（`ProfileSubscriptionHTTPResponse.headers`） |

## 3. 功能设计

### 3.1 连接页显示来源 App

**用户体验**
- 连接列表新增"应用"列：App 图标 + 名称（如"Google Chrome"），悬停显示签名标识与可执行文件路径。
- 新增"按应用分组"视图：每个 App 一行，显示连接数和上下行合计，可展开查看具体连接。
- 新增应用筛选，可与现有的目标、规则筛选组合使用。
- 连接行右键菜单："此应用始终直连 / 始终走代理 / 始终拒绝"，直接生成 3.2 的应用规则。
- 无法识别来源时显示"未知应用"（而不是留空），并在说明里写清原因（例如 TUN 模式的限制，见 3.4）。

**技术方案**
- **扩展 → 引擎**：新增 `clash_flow_tcp_create_v2` / `clash_flow_udp_create_v2`，多传一段来源 App 描述：`signing_identifier`（必有）、`executable_path`（可选，由审计令牌解析，失败则为空）。保留 v1 接口，旧调用不受影响。
- **引擎**：`Session` 增加 `source_app: Option<SourceApp>`；跟踪的连接元数据带上它。
- **遥测**：遥测格式升级到 v2，每条连接追加 `app_identifier`、`app_path` 两个有长度上限的字符串字段（上限沿用 `MAXIMUM_TELEMETRY_STRING_BYTES`）；Swift 解码同时支持 v1 与 v2。
- **App 展示**：由签名标识或路径找到 `.app` 包，用 `NSWorkspace` 取图标和显示名，结果缓存。辅助进程（如 `com.google.Chrome.helper`）按签名标识前缀和路径归并到主 App。
- **已知需要特殊处理的系统进程**：Safari 的网络请求实际由 `com.apple.WebKit.Networking` 发出，后台下载可能由 `nsurlsessiond` 发出。内置一张小映射表（WebKit.Networking → Safari 等），映射不了的照实显示进程名，并在帮助里说明。

### 3.2 按 App 分流

**用户体验**
- 规则页新增"应用规则"分组，位于"自定义规则"之上：
  - "添加应用"：从"最近联网的应用"（来自连接页）中选择，或用文件选择器选 `.app`；
  - 策略：直连 / 走代理（可选具体策略组）/ 拒绝；
  - 列表显示图标、名称、策略，支持启用 / 停用和删除。
- 优先级：**应用规则 > 自定义规则 > 配置中的规则**。也就是说，"让某个 App 直连"会覆盖针对某个域名的自定义规则。这个顺序在界面上直接说明。
- 路由预览（"输入网址看看走哪条线路"）在存在应用规则时提示"结果还取决于发起请求的应用"。

**技术方案**
- **数据模型**：`CustomRuleStore` 新增应用规则类型，保存 `bundleIdentifier`、`bundlePath`、显示名、策略、启用状态；编码兼容旧数据。
- **规则编译**：应用规则在生成运行配置时置于最前，编译成引擎规则。引擎新增一种内部规则（仅由 App 生成，不对外暴露），匹配条件为：会话的签名标识等于或以 `bundleIdentifier.` 开头，或可执行文件路径位于 `bundlePath/` 之下。
- **兼容 mihomo 规则**：同时让透明代理流量支持配置文件中已有的 `PROCESS-NAME`、`PROCESS-PATH`（以及 mihomo 的 `PROCESS-PATH-REGEX`），用会话里的来源 App 信息匹配，不再加载报错。
- **TUN 模式**：取决于 3.4 的技术验证结果；验证不通过时，应用规则在 TUN 模式下不生效，界面明确提示"按应用分流需要透明代理模式"。

### 3.3 订阅流量与到期提醒

**用户体验**
- 配置页的订阅卡片显示：已用 / 总量的进度条、剩余流量、到期日期（剩余天数）。
- 剩余流量低于 10% 或距到期不足 3 天时，卡片显示提醒；可选在菜单栏面板显示一行提示。是否发送系统通知作为可选项（默认关闭，开启时才申请通知权限）。

**技术方案**
- 解析 `subscription-userinfo`：`upload=…; download=…; total=…; expire=…`，字段缺失或格式不规范时宽松处理（忽略该字段），数值做溢出保护。
- 解析结果随订阅元数据保存（`ProfileSubscription` 新增可选字段，兼容旧数据），每次刷新订阅时更新，并记录获取时间。
- 顺带支持 `profile-update-interval`（服务端建议的更新间隔，单位小时），在用户未自定义时作为默认自动更新间隔；`content-disposition` 中的文件名作为新订阅的默认名称。

### 3.4 先做技术验证（M0，决定 TUN 的范围）

在动手实现前，用 1–2 天验证以下问题，结果写进本文件后再定 TUN 的范围：

| 问题 | 验证方法 | 通过标准 |
|---|---|---|
| 沙盒内的 Packet Tunnel 扩展能否按五元组查到进程 | 在扩展内调用 `sysctl net.inet.tcp.pcblist_n` / `proc_pidpath`（或启用 `sock2proc`），对 curl、Chrome、Safari 的连接取样 | 能拿到 pid 和路径；不需要新增敏感权限 |
| 查询开销 | 每条新连接查一次，测 p50 / p95 | p95 < 1 ms；超过则改为异步查询：只用于展示，不阻塞路由 |
| 透明代理审计令牌转路径 | 扩展内用审计令牌取 pid，再取路径 | 能拿到时补充路径；拿不到时只用签名标识，功能不受影响 |
| 签名标识覆盖率 | 统计常用 App（浏览器、Electron、命令行工具、系统服务）的签名标识形态 | 归并规则覆盖主流 App；无签名的命令行工具有合理的显示名 |

**决策**：
- TUN 验证通过 → TUN 同样支持应用识别与应用规则；
- 只能做到展示 → 连接页显示 App，但应用规则只在透明代理下生效；
- 都不行 → TUN 下显示"未知应用"，按 App 分流明确要求透明代理模式。

## 4. 涉及的主要文件

| 位置 | 改动 |
|---|---|
| `Sources/AetherRouteTransparentProxy*/` | 建流时读取并传入来源 App 信息；审计令牌解析 |
| `Core/Engine/clash-ffi/src/flow_ffi.rs` | `*_create_v2` 接口；遥测 v2 编码 |
| `Core/Engine/clash-lib/src/session.rs`、`embedded_flow.rs`、`app/router/rules/` | 会话来源 App；内部应用规则；透明代理下放开 `PROCESS-*` 规则 |
| `Core/Engine`（TUN，视 M0 结果） | 进程查询（`sock2proc` 或自研最小实现） |
| `Sources/AetherRouteKit/NetworkTelemetry.swift` | 遥测 v1/v2 解码 |
| `Sources/AetherRouteKit/CustomRule.swift`、`CustomRuleStore.swift`、`DomesticRoutingOptimizer.swift` | 应用规则模型、存储、编译与优先级 |
| `Sources/AetherRouteKit/ProfileSubscription.swift` | `subscription-userinfo`、`profile-update-interval`、文件名解析与保存 |
| `Sources/AetherRouteApp/ConnectionsPageView.swift`、`ConnectionTableItem.swift` | 应用列、分组、筛选、右键菜单 |
| `Sources/AetherRouteApp/RulesPageView.swift` | 应用规则分组与添加流程 |
| `Sources/AetherRouteApp/ProfilesPageView.swift`、菜单栏面板 | 订阅流量卡片与提醒 |
| `Localizable.xcstrings`、帮助主题 | 文案与说明（含 TUN 限制、Safari 映射） |
| `Config/ProtocolCoreEvidence.json`、许可证清单 | 引擎变更后同步；若启用 `sock2proc` 需补许可证审查 |

## 5. 测试计划

**引擎单元测试**
- 来源 App 从流创建接口传到会话、再进入遥测的完整链路；v1 接口仍可用。
- 应用规则匹配：签名标识相等或前缀、路径前缀、辅助进程归并、不误匹配同名前缀（如 `com.google.Chrome` 不能匹配 `com.google.ChromeX`）。
- 透明代理下 `PROCESS-NAME` / `PROCESS-PATH` 加载并生效。
- 遥测 v2 编码：字符串长度上限、非 UTF-8 清理。

**App 单元测试**
- 遥测 v1/v2 解码；应用归并与 Safari 映射表。
- 应用规则的存储兼容、编译顺序（位于最前）与策略生成。
- `subscription-userinfo` 解析：完整、缺字段、大小写、空格、超大数值、负数、非法值；`profile-update-interval` 与文件名解析。

**端到端验收（扩展 `scripts/test_runtime_acceptance.sh`）**
- **来源识别**：用 `curl` 发请求，通过 QA 自动化接口读取遥测，确认连接归属为 curl。
- **应用分流**：给 curl 加"直连"应用规则后，出口 IP 应为本地宽带 IP；改成"走代理"后应为节点 IP（复用"对比出口 IP"的检查思路）。
- 透明代理与 TUN 各跑一次；TUN 的预期结果按 M0 结论写定。

**发布门禁**：完整 SOP，包括本地回归、协议互通门禁、虚拟机 6 维矩阵（需先恢复 `macos27`）、Mac mini 真机双模式、公证发布。

## 6. 风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| TUN 下无法识别进程（沙盒限制） | TUN 用户没有按 App 分流 | M0 先验证；界面诚实提示需要透明代理模式；透明代理本来就是推荐的默认模式 |
| 进程查询拖慢新连接 | 首包延迟增加 | 设定 p95 < 1 ms；超出则改为异步，只用于展示 |
| 归并不准（辅助进程、系统代发） | 规则对某些 App 不生效 | 前缀 + 路径双重匹配；内置映射表；连接页显示真实进程，便于用户自查 |
| 遥测格式升级 | App 与扩展版本不一致时解析失败 | 同时支持 v1/v2；扩展与 App 同版本发布 |
| 隐私 | 连接记录包含 App 信息 | 只在本机内存中使用，不上传；诊断报告默认不包含 App 信息，用户勾选后才附带 |
| 订阅信息格式不规范 | 显示错误数值 | 宽松解析，异常字段忽略，不影响订阅更新本身 |
| 虚拟机尚未恢复 | 发布验证不完整 | 发布前恢复 `macos27`；否则沿用 1.2.0 的真机替代方案并写入例外说明 |

## 7. 里程碑

| 阶段 | 内容 | 预计 |
|---|---|---|
| M0 | 技术验证（3.4），写下结论与 TUN 范围 | 1–2 天 |
| M1 | 订阅流量与到期提醒（独立、风险最低，可先合入） | 1 天 |
| M2 | 来源 App 链路：扩展 → 引擎 → 遥测 v2 → 连接页（应用列、分组、筛选） | 2–3 天 |
| M3 | 按 App 分流：引擎内部规则、`PROCESS-*` 支持、规则页、连接页右键菜单 | 2–3 天 |
| M4 | TUN 支持（视 M0 结论）、端到端验收脚本、帮助文案 | 1–2 天 |
| M5 | 完整发布流程，发布 1.3.0 | 0.5–1 天（主要是机器时间） |

## 8. 需要确认的问题

1. **规则优先级**：应用规则放在自定义规则之上（"App 直连"覆盖域名规则），是否同意？
2. **TUN 的取舍**：如果 M0 验证显示 TUN 下无法识别进程，是否接受"按 App 分流只在透明代理模式下生效"？
3. **系统通知**：订阅即将到期或流量不足时，是否需要系统通知（默认关闭、开启时申请权限），还是只在 App 内提醒？
4. **发布节奏**：M1（订阅流量）独立且风险低，是否先单独发一个小版本（如 1.2.1），还是和其余功能一起在 1.3.0 发布？
