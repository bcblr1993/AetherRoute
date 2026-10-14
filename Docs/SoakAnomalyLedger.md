# AetherRoute 16小时浸润监控异常与待修复事项台账 (Soak Anomaly Ledger)

> **创建时间**：2026-10-13 20:10  
> **监控环境**：  
> - 本机：macOS Apple Silicon (透明代理模式，2分钟采样)  
> - 远端：Mac mini 100.64.0.3 (虚拟网卡 TUN 模式，2分钟采样)  
> **跟踪状态**：已建档，待后续排期排查与修复

---

## 异常清单与修复路线图

### 📌 [ISSUE-01] 冷启动首发 IPC 偶发 5 秒超时 (优先级: P2)
- **发现时间**：2026-10-13 16:44:27
- **现象日志**：
  ```text
  stage=providerMessage hostSend failed error=AetherRoute.TunnelManagerError.providerMessageTimedOut consecutiveUnresponsive=1
  ```
- **影响范围**：透明代理冷启动后前 5~10 秒内，宿主 App 发出的首个状态/遥测探针可能偶发超时判定，虽不触发重连，但在控制台留下 Error。
- **根因定位**：
  1. `TransparentProxyUpstreamEndpointResolver.resolve` 在 `startProxy` 同步代码中调用系统 `getaddrinfo` 解析配置中的上游节点，慢节点可能阻塞数秒；
  2. 系统 NetworkExtension 从 `connecting` 切换到 `connected` 的初建阶段，XPC 管道存在毫秒级排队；
  3. App 端 `sendProviderMessage` 默认超时设为较紧的 5 秒，而扩展端看门狗为 15 秒。
- **修复方案**：
  - [ ] 将 `TransparentProxyUpstreamEndpointResolver` 改造成异步并发解析，并设置单节点解析超时；
  - [ ] 宿主 App 针对初次连接成功后的握手探测提供自适应超时（如 10 秒）或 1 次静默快速重试。

---

### 📌 [ISSUE-02] 透明代理应用层短连接并发关闭竞态日志 (优先级: P3)
- **发现时间**：2026-10-13 16:45:19 起持续偶发（每 15 分钟数十至数百条）
- **现象日志**：
  ```text
  [com.apple.networkextension:] (1358472809): flow is closed for writes, cannot write 6367 bytes of data
  Failed to write flow Data
  ```
- **影响范围**：控制台产生系统级红色报错。实际业务层已正确映射为 `peerClosed`，无功能影响，但影响日志纯净度。
- **根因定位**：
  - 浏览器（Chrome 等）主动断开连接（发送 TCP FIN/RST）与远端响应到达在毫秒级并发重叠。内核关闭写端后，`NEAppProxyTCPFlow.write` 打印系统级错误。
  - **对照证据**：在 Mac mini 运行的 L3 **TUN 模式下该错误为 0**（TUN 模式无应用层套接字关闭竞态）。
- **修复方案**：
  - [ ] 在 `NetworkExtensionFlowAccess.swift` 中，若已检测到半关闭事件，提前熔断后续对 `flow.write` 的调用，减少对已关闭流的无效写操作。

---

### 📌 [ISSUE-03] UDP Flow 超短生命周期撤销报错 (优先级: P3)
- **发现时间**：2026-10-13 19:45:51
- **现象日志**：
  ```text
  stage=nativeOpen failed transport=udp domain=NEAppProxyFlowErrorDomain code=5 remote=n/a elapsedUs=122
  ```
- **影响范围**：日志打印 Error 级别记录，无业务影响。
- **根因定位**：
  - 应用程序在发起 UDP 数据报后极短时间（122 微秒）内主动注销了 Socket（`NEAppProxyFlowError.cancelled` / code 5），导致扩展回调时该流已被系统取消。
- **修复方案**：
  - [ ] 在 `TransparentNativeFlow.swift` / `handleNewUDPFlow` 中，对 `domain=NEAppProxyFlowErrorDomain code=5` 识别为客户端主动撤销（Client Cancelled），将其日志降级为 `verbose`。

---

### 📌 [ISSUE-04] 高并发 UDP 流量突发时系统网络缓冲池短时耗尽 (优先级: P2)
- **发现时间**：2026-10-13 19:33:41
- **现象日志**：
  ```text
  [com.apple.networkextension:] (0): data: failed to write a message: no buffer space available
  ```
- **影响范围**：并发流量突发（95 个并发 UDP 会话）时，系统内核 UDP 缓冲池瞬时满载丢包。
- **根因定位**：
  - 短时间内密集向 NetworkExtension 内核通道写入 UDP 数据报，超出内核 socket 缓冲区（ENOBUFS: errno 55）。
- **修复方案**：
  - [ ] 在 `TransparentProxyFlowSession.swift` 的 `writeDatagrams` 中引入自适应批处理分片与微秒级背压退避重试，避免瞬时大包暴击内核缓冲池。

---

### 📌 [ISSUE-05] Sparkle 2.x 后台应用更新提示机制告警 (优先级: P3)
- **发现时间**：2026-10-13 16:44:17
- **现象日志**：
  ```text
  [org.sparkle-project.Sparkle:Sparkle] Warning: Background app automatically schedules for update checks but does not implement gentle reminders.
  ```
- **影响范围**：App 启动时在控制台产生 1 条警告。
- **根因定位**：
  - Sparkle 2.x 对纯后台/菜单栏应用推荐实现 Gentle Reminders 委托协议，当前配置未显式声明该策略。
- **修复方案**：
  - [ ] 在 `SparkleUpdater` / AppDelegate 中适配 `SPUUpdaterDelegate` 的温柔提醒接口。

---

### 📌 [ISSUE-06] 图形窗口常驻时 Malloc Small 内存平台期偏高 (优先级: P2)
- **发现时间**：2026-10-13 20:55:30 (Mac mini 监控)
- **现象特征**：
  - 本机 App 窗口关闭/仅菜单栏时：RSS 约 188~200 MB；
  - Mac mini 启动并保留图形主窗口时：RSS 攀升至 441.6 MB 后停滞进入平台期，`vmmap -summary` 显示实际 Physical Footprint 为 296.3 MB（其中 Malloc Small 堆内存分配 288.2 MB）。
- **影响范围**：前台长时间开启主窗口时，SwiftUI / 遥测视图频繁重绘可能造成小对象分配累积，直至到达稳态上限。
- **根因定位**：
  - 实时遥测视图（连接列表、速率图表、节点状态）在每秒刷新时产生的短生命周期对象与字形缓存堆积，窗口处于前台时 GC 回收滞后。
- **修复方案**：
  - [ ] 对实时遥测视图启用 `@StateObject` 节流或视图隐藏/非活动时的自动暂停机制；
  - [ ] 复用数据缓冲管道（DataPlaneSampler），降低高频重绘下小对象的创建频率。

---

### 📌 [ISSUE-07] Sparkle Appcast 多语言 XML 元素缺少 xml:lang 属性标记 (优先级: P3)
- **发现时间**：2026-10-13 21:08:39 (Mac mini 监控)
- **现象日志**：
  ```text
  [org.sparkle-project.Sparkle:Sparkle] Error: Multiple nodes for description element are present and one of them does not have xml:lang attribute specified. Defaulting to xml:lang="en"...
  [org.sparkle-project.Sparkle:Sparkle] Error: Multiple nodes for sparkle:fullReleaseNotesLink element are present and one of them does not have xml:lang attribute specified.
  ```
- **影响范围**：后台或主动检查更新时，Sparkle 解析 `appcast.xml` 在控制台打印 3 条配置属性缺失提示，不影响更新下载与校验，但影响发布清单规范性。
- **根因定位**：
  - `generate_sparkle_appcast.sh` 生成的多语言 `description` 和 `fullReleaseNotesLink` 标签中，部分默认语言节点未显式包含 `xml:lang="en"` 属性，导致 Sparkle 回退到隐式推断。
- **修复方案**：
  - [ ] 优化 `scripts/generate_sparkle_appcast.sh`，在生成所有 `description` 和 `sparkle:fullReleaseNotesLink` 节点时，均显式追加 `xml:lang="en"` 和 `xml:lang="zh-CN"` 属性。

---

## 监控沉淀索引
- **异常持久化日志**：`scratch/soak_anomalies_16h.log`
- **本机时序数据**：`scratch/soak_metrics_16h.csv`
- **Mac mini TUN 时序数据**：`chenxu@100.64.0.3:~/soak_metrics_tun_16h.csv`
