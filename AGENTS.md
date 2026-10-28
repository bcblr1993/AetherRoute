# AetherRoute macOS - Engineering, Verification & Release Standards (SOP)

## 🛡️ Zero-Bundle & Security Standards (Mandatory / 绝对硬性红线)
1. **No Bundled User Profiles or Subscriptions**:
   - The application bundle must **NEVER** contain any developer or personal configuration archives, test servers, private credentials, or subscription URLs (`*.aetherroute`, `*.yaml`, `*.conf`).
   - All `.aetherroute` archives are strictly blocked by `.gitignore`.
2. **Pre-Release Security Validation**:
   - All release builds must pass security checks ensuring no private keys, seed profiles, or test credentials leak into distribution artifacts.

---

## 🚀 Standard Release & Delivery Lifecycle (发布与全量验证标准 SOP)

每次代码优化、特性迭代或版本发布时，AI 助手**必须主动、自动化**执行以下标准流水线，无需维护者重复提醒：

### 1. 本地代码与单元回归测试
- 确保所有修改的代码编译通过且零警告。
- 运行核心回归测试套件：
  ```bash
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_network_switch_gate.py
  sh Tests/EngineReconnect/run.sh
  sh Tests/RuntimeEnvironment/run.sh
  ./scripts/test.sh
  ```
  - 核心回归已内嵌并强制执行 Shadowsocks 插件与混淆配置门禁（`scripts/test_plugin_obfs_subscription_gate.sh`），验证 `plugin: obfs`、`v2ray-plugin`、`shadow-tls` 内置插件与真实 Clash Verge 订阅加载通过，并严防任意可执行命令/未知插件注入。
  - 核心回归已内嵌并强制执行菜单栏自定义图标门禁（`Tests/MenuBarIcon/run.sh`），验证全量 41 款配对 SF Symbols 矢量图形有效性、未连接/已连接双态平滑切换、更新红点 Badge 渲染、以及配置持久化与未知非法值安全回退。
  - 核心回归已内嵌并强制执行菜单栏实时网速流量门禁（`Tests/MenuBarTraffic/run.sh`），验证默认关闭边界、开关持久化与回退、等宽紧凑速率格式化（B/s、KB/s、MB/s、GB/s）、全量 41 款 SF Symbols 双态及红点 Badge 的像素级对齐渲染、未连接状态安全归零、以及高频遥测观察范围隔离（零无感刷新与零泄漏）。
  - 核心回归已内嵌并强制执行允许局域网（局域网共享代理）门禁（`Tests/AllowLAN/run.sh`），验证默认安全边界（默认关闭、端口 7890/7891）、物理 IPv4 提取与虚拟接口过滤、真实本地 Socket 代理握手（HTTP CONNECT 隧道透传、绝对路径 HTTP GET、SOCKS5 握手与中继）、向后兼容性与多端保姆级教程完整性。
  - 核心回归已内嵌并强制执行网络恢复状态机与第三方订阅协议兼容门禁（`scripts/test_recovery_and_subscription_compat_gate.sh`），验证 `.recovering` 自动重连状态转换无死锁、首次启动失败立即报错不空转、国内直连健康探测优先 Apple 节点、DNS 行内注释与数组策略规范化、Mihomo `include-all`/`filter` 策略组展开、以及 Rust 双引擎容错跳过混合订阅中不支持的旧协议节点（如 `ssr`/`snell`）与缺失字段默认值兼容。
- **测试先行（TDD，Mandatory，1.10.0 起）**：所有功能开发与缺陷修复都先写测试，运行确认它失败（新功能）或能抓住问题（对已有代码做一次变异验证），再写实现直到通过，最后接入下面的门禁。提交说明或 CHANGELOG 要写明测试在旧代码上失败。
- **Mihomo 对照门禁（Mandatory，1.10.0 起）**：
  - 每次发布与 `Core/Engine` 改动都必须运行 `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_subscription_differential.py --e2e`。它在本机回环上用 sing-box 当服务端，同时驱动 Mihomo 和我们的引擎（`build/differential-target/release/clash-rs`，与 App 相同的特性集），必须得出：能用的节点两边都通、死节点两边都失败、不支持的传输层节点被我们跳过（`ours_missing`），而且其余节点照常可用。单元部分已接入 `test.sh`。
  - 用户反馈"某订阅有问题"时，先运行 `scripts/compare_subscription_with_mihomo.sh <订阅 URL 或文件>`。本机有隧道或透明代理时，设置 `AETHER_DIFFERENTIAL_HOST=chenxu@100.64.0.3`，改在 Mac mini 上测。报告列出 Mihomo 能用、而我们不能用或没加载的节点，并按协议和选项汇总。订阅和配置只存在于临时目录，报告不含服务器地址和凭据。该工具在 1.10.0 开发中发现：订阅里只要有一个 `xhttp` 或 `httpupgrade` 节点，两个核心都会拒绝整份配置。
- **日常快速门禁（fast lane，1.10.0 起）**：每次提交前运行 `./scripts/test_fast_lane.sh`。它只在本机运行，不碰本机网络、隧道和系统扩展，依次执行上面四项核心回归里的快速部分（网络切换、引擎重连、运行环境、网络快照）、大上传门禁、恢复与订阅兼容门禁、Mihomo 对照单元测试，以及差分引擎增量构建加端到端对照。`Core/Engine` 有未记录的改动时自动加跑 12 协议互通门禁，也可用 `AETHER_FAST_LANE_INTEROP=1` 强制加跑。每步输出 PASS/FAIL 和耗时，日志在 `outputs/fast-lane-<时间>/`。它不能代替发布前的完整 `test.sh` 和下面的验收流水线。
- **核心功能必须带回归测试（Mandatory，1.9.1 起）**：凡是新增或修复核心功能（连接生命周期与自动恢复、订阅解析与配置重写、DNS 与路由、透明代理与 TUN、`Core/Engine` 协议收发），同一次提交必须附带能复现原问题的单元测试或门禁用例，并接入上面的核心回归或互通门禁，使其随每次发布自动运行。修复必须先确认测试在旧代码上失败、在新代码上通过；无法自动化的场景要在 CHANGELOG 写明原因和手工验证步骤。没有测试的核心改动不得进入发布。
- 运行 12 种协议的真实互通门禁（`test.sh` 只校验运行脚本文本，不会真正连接）。首次运行先下载并校验第三方服务端（sing-box、shadow-tls、Xray、Mihomo，均按固定 SHA-256 校验；WireGuard 服务端从源码编译），缓存在已被忽略的 `build/interop-tools`：
  ```bash
  ./scripts/fetch_interop_tools.sh
  ./scripts/test_protocol_interop_all.sh
  ```
  门禁编译与发布一致的 release 引擎，在本机回环上逐一对接 sing-box 矩阵（24 个用例）、VLESS REALITY、WireGuard、ShadowQUIC 与 OpenSSH；每个用例都检查 2 MiB 双向传输、空闲后复用、8 包 UDP（重复送达即失败），TLS 用例还必须通过证书指纹固定（Hysteria2、TUIC 另测 `ca-str` 自定义 CA）、拒绝错误指纹，并在开启证书校验时拒绝不受信任的证书（服务端证书由 `Tests/Interop/make-test-pki.sh` 生成的临时 CA 签发）。五项必须全部 PASS，日志与汇总在 `outputs/interop-<时间>/`。该门禁曾发现 Shadowsocks UDP 重复发包与 SSH 空闲 5 秒断开（1.1.7 修复），以及 Trojan UDP 帧跨 TLS 记录时读写错位导致的 `payload changed`（1.9.1 修复；偶发失败也必须查明，不得当作抖动重跑放行）。
  - 每次发布都必须运行；`Core/Engine` 有任何改动时必须在提交前运行。
  - 修改 `interop_tests.rs` 后同步 `Config/ProtocolCoreEvidence.json`（`coreCommit`、`interopTestsSHA256`、`interopCases`）与 `Config/ProtocolReleaseMatrix.json`，并以 `./scripts/verify_protocol_matrix.sh` 校验。
  - REALITY 用例的 Xray 服务端每次握手都会访问真实的 www.cloudflare.com，本机网络繁忙时单轮会慢 5–10 秒；单项超时先单独重跑该项确认，不要放宽其他用例。
  - 排查时可用 `AETHER_INTEROP_CASES=名称,名称` 只跑部分矩阵用例，`AETHER_INTEROP_PROFILE=debug` 加快编译。

> **第 2 步与第 3 步并行自动化执行（Mandatory SOP）**：QA 候选包构建与双端验证现已通过并行流水线脚本完全自动化：
> ```bash
> ./scripts/run_release_acceptance_parallel.sh <VERSION> <BUILD>
> ```
> 该脚本先以生产级正常核心（`AETHERROUTE_TEST_CORE_VARIANT=normal`）构建 QA 候选包，再并发驱动三条轨道（1.10.0 起）：
> 1. **Tart 虚拟机**：6 维引擎×路由矩阵验收（含透明代理 5 项专项门禁），通过后在同一台 VM 上运行远程 arm64 源码门禁（`test_remote_arm64.sh <VM 用户>@<VM IP> fast`）。两者先后执行，不会同时占用 VM。
> 2. **Mac mini**：`test_ui_performance_gate.sh`。设置 `AETHERROUTE_REMOTE_GATE_HOST=chenxu@100.64.0.3` 可把远程门禁改回 Mac mini，在 UI 性能门禁之前运行。
> 3. **本机**：stable 公证候选 DMG（`AETHERROUTE_CANDIDATE_CHANNEL=stable`，公证配置取 `AETHERROUTE_NOTARY_PROFILE`，默认 `AetherRoute-Notary`）。网络快照已忽略 Tart VM 的 `vmenet*`/`bridge1xx` 网卡和 bridge 上的 scoped 默认路由，所以 VM 运行或启停不会再让候选构建误报"系统网络状态已改变"。
>
> 三条轨道都通过后，Mac mini 已经空闲，脚本用 `scripts/collect_physical_runtime_pair.sh` 在 Mac mini 上安装该公证 DMG，先后以 TUN、透明代理连接，采集六项物理机证据，再用 `verify_parallel_acceptance.py evidence` 按该 DMG 的 SHA-256 校验，最后打印 `package_release_dmg.sh` 需要的证据目录。采集脚本会备份 Mac mini 的偏好设置，退出时恢复。
> `AETHERROUTE_ACCEPTANCE_PLAN_ONLY=1` 只打印执行计划，不构建、不 SSH、不启动 VM（`test_parallel_acceptance_policy.py` 用它校验编排）。缩短或跳过任何门禁的设置仍会在开始前被拒绝。
>
> **VM 上的远程门禁环境**：`macos27` 没有 Homebrew，也没有免密 sudo。Go 装在 `~/sdk/go`（与 Mac mini 同版本，按官方 SHA-256 校验），ripgrep 用官方静态发布版放在 `~/sdk/bin`。worker 在开始前检查 `go gofmt jq python3 rg`，缺任何一个立即失败，不会等到 `test.sh` 跑了一小时才报错。VM 需至少 6 核、16 GB 内存，`/tmp` 有 8 GB 以上空闲空间（磁盘扩容见 VM 磁盘说明）。
>
> **物理机运行时证据（绑定公证候选 DMG）**：Mac mini 的系统扩展只加载公证构建，QA ZIP 只能在 VM 的开发者模式里运行。证据规则：
> 1. 切换网卡会打断同一台 Mac mini，所以证据只在 UI 性能门禁（以及改到 Mac mini 上的远程门禁）结束后采集；
> 2. 单独补采时执行 `AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES scripts/collect_physical_runtime_pair.sh <DMG 绝对路径> [证据目录]`，或按引擎分别执行 `scripts/collect_physical_runtime_evidence.py <DMG> chenxu@100.64.0.3 tun|transparent <证据目录>`（默认目录 `outputs/physical-runtime-<VERSION>-<BUILD>`）；
> 3. `package_release_dmg.sh` 只接受 `.dmg` 来源，并在任何签名、公证之前校验与该 DMG 的 SHA-256、构建号、主机绑定的六项证据（TUN/透明代理 × 空闲复用、2 MiB 上传、切换网卡），缺失或不符即拒绝打包。
> 详见 `Docs/LANProxyRegression.md`。

### 2. Tart 虚拟机矩阵自动化测试与清理 (VM Matrix Acceptance)
- 虚拟机名称标准：`macos27`（本地 Tart VM，统一使用；不再使用 `aether-diag-1434`）。
- 构建 QA 自动化测试候选包：
  ```bash
  AETHERROUTE_TEST_CORE_VARIANT=normal ./scripts/build_signed_local_test_candidate.sh Config/Signing.json <VERSION> <BUILD> outputs/qa-candidate-<VERSION>-<BUILD>
  ```
- 运行 6 维网络矩阵与生命周期测试：
  ```bash
  ./scripts/test_vm_acceptance_matrix.sh outputs/qa-candidate-<VERSION>-<BUILD>/<ZIP_FILE> macos27 outputs/vm-acceptance-<VERSION>-<BUILD>
  ```
- 矩阵的每个"引擎 × 路由"组合都包含 **空闲 keep-alive 复用检查**（`scripts/test_idle_keepalive_reuse.sh`，由 `test_runtime_acceptance.sh` 调用）：同一条 TLS 连接空闲 50 秒后再次请求必须成功。`tun` 与 `transparent` 两个引擎都必须 PASS，任一 FAIL 即阻断发布（`direct` 模式自动判定 SKIP，免去无效等待）。
- `transparent` 引擎的组合包含以下 **透明代理 5 大专项门禁**（任一 FAIL 即阻断发布）：
  1. **SNI 目标恢复检查**（`scripts/test_transparent_sni_recovery.sh`）：验证 ClientHello 的真实 SNI 转发与证书有效性，防止 IP 污染导致应用断连。
  2. **原生 UDP 数据报接管与转发**（`scripts/test_transparent_udp.sh`）：发起原生 UDP DNS (53) 数据报查询，验证扩展接管、合成端口池映射与双向完整收发。
  3. **LAN/Loopback 直连穿透**（`scripts/test_transparent_lan_bypass.sh`）：验证本机回环（127.0.0.1）与私有局域网直连流量直接绕过代理扩展，零延迟穿透。
  4. **明文 HTTP 与裸 IP 目标处理**（`scripts/test_transparent_raw_traffic.sh`）：验证纯明文 HTTP 80 与无 SNI 裸 IP 目的地的透明代理安全转发。
  5. **瞬时突发高并发压测**（`scripts/test_transparent_burst_concurrency.py`）：以 60 并发短连接瞬时冲击透明代理流表，验证无连接重置、并发稳定承载且 Session 正常释放。
- 矩阵的每个组合还包含 **大请求上传检查**（`scripts/test_large_upload.sh`）：经代理向 `speed.cloudflare.com/__up` 上传 2 MiB 随机数据，必须 HTTP 200 且服务端回报的 `cf-meta-upload-bytes` 等于发送字节数（`AETHERROUTE_LARGE_UPLOAD_URL` 可换回 httpbin 兼容的回显端点逐字节比对；httpbin.org 自 2026 年 10 月起拒收超过 64 KiB 的请求体，曾使 1.9.1 矩阵六项全部误报失败）。该检查防止出站协议在客户端写入快于节点上行时破坏分帧（曾因 VLESS Vision 帧长 u16 溢出，导致 Claude Code 等大上下文请求 `ECONNRESET`）。`tun` 与 `transparent` 都必须 PASS；`direct` 路由下若连小请求都不通记为 SKIP。
- **清理规范（Mandatory）**：
  - 测试完成后必须立即清理虚拟机内的安装包、解压临时目录及相关日志记录，保持 VM 干净。

### 3. 物理真机环境验证 (Remote Hardware Validation)
- 物理设备标准：`chenxu@100.64.0.3` (Apple Silicon Mac mini)。
- 远程自动化源码门禁（1.10.0 起默认由并行流水线在 `macos27` VM 上运行，见上文；单独运行或改回 Mac mini 时）：
  ```bash
  AETHERROUTE_ALLOW_REMOTE_GATE=YES ./scripts/test_remote_arm64.sh chenxu@100.64.0.3 fast
  ```
- 门禁把源码快照和测试用例无损同步到目标机，两端按清单逐文件比对 SHA-256，在目标机上执行完整 `test.sh` 并检查网络状态未变，确保 100% 通过。
- **空闲 keep-alive 复用（Mandatory，TUN 与透明代理各一次）**：在物理机上安装候选包，分别以 TUN 模式和透明代理模式连接后执行：
  ```bash
  sh scripts/test_idle_keepalive_reuse.sh
  ```
  两种模式都必须输出 `both requests answered` 并以 0 退出。该检查防止引擎再次在 60 秒空闲后关闭本机客户端连接（曾导致 Claude Desktop / Claude Code 会话 `ECONNRESET` 中断）。
- **大请求上传（Mandatory，TUN 与透明代理各一次）**：同样在两种模式下执行 `sh scripts/test_large_upload.sh`，必须输出 `bytes delivered` 并以 0 退出。
- **切换网卡自动恢复（Mandatory，1.7.1 起每次发布，TUN 与透明代理各一次）**：物理机连接后，在本机执行：
  ```bash
  sh scripts/test_remote_interface_switch.sh chenxu@100.64.0.3
  ```
  脚本把物理机的首选网络服务在有线 `en0` 与 Wi-Fi `en1` 之间来回切换（默认 3 轮、共 6 次）。每次切换后，经代理访问 `https://www.google.com/generate_204` 必须在 15 秒内自动恢复，不得手动断开重连。必须输出 `PASS: interface switch recovered` 并以 0 退出；FAIL 阻断发布，INCONCLUSIVE（缺少第二块网卡、切换没有生效、或切换前就不通）必须查明原因后重跑。结果里有每次切换的恢复秒数，写进 CHANGELOG。脚本在物理机上后台运行，切换时 SSH 会断，本机脚本会自动重连等结果；退出时会恢复原来的服务顺序。要用 Tailscale 地址登录：切换网卡时局域网地址也会跟着变。该检查源于 1.7.1 之前的缺陷：透明代理把出站连接固定在启动时的网卡上，从 Wi-Fi 换到有线网卡后一直不通，只能手动重连；同一网卡上换网络（Wi-Fi 换热点）不受影响，所以以前的网络切换测试（在 en0 上加地址别名）发现不了。
- **UI 卡顿与内存预算门禁（Mandatory，1.5.1 起每次发布）**：在本机执行，脚本自行构建带探针的 Release 审查版，并在物理机的图形会话里运行（不触碰本机隧道）：
  ```bash
  ./scripts/test_ui_performance_gate.sh "$PWD/outputs/perf-gate-<VERSION>-<BUILD>"
  ```
  App 以中文界面、每秒跳动的实时遥测，在"展示"（日常，十几条连接）和 `large`（500 节点 / 1 万条规则 / 2000 条连接）两档夹具下各自动切页 5 分钟；每次切页从选中计到主线程完成布局与提交，同时全程采样实际占用（活动监视器"内存"列口径）。预算见脚本顶部（切页 p95 与最大值、内存中位数与峰值、后半程增长），任一超标即以非零退出并**阻断发布**，`result.txt` 写明超标项。放宽预算必须在 CHANGELOG 说明原因。该门禁源于 1.5.0 的两个回归：切页主线程卡顿最高 0.8 秒（旧探针在 SwiftUI 首次渲染时就停表，看不到布局）；每秒刷新的数字做滚动动画，把 CoreGraphics 字形缓存撑到约 90 MB（App 涨到 150–210 MB）。
  - 不能用 XCUITest 的 `test_ui_responsiveness.sh` 代替：测试运行器的沙盒在物理机上写不了证据，且它的夹具数字静止。
  - 排查时可用 `AETHERROUTE_PERF_PROFILES=large`、`AETHERROUTE_PERF_SECONDS=120` 缩短；发布必须用默认值。

### 4. 版本迭代与 CHANGELOG 维护
- 依据语义化版本推进（如当前版本至下一版本）。
- 完整编写 `CHANGELOG.md`，包含：
  - 本次修复与优化内容说明；
  - 虚拟机 6 维矩阵与物理硬件测试验证结论；
  - UI 卡顿与内存预算门禁的结论（`result.txt` 里两档的切页 p95 / 最大值与内存中位数 / 峰值）；
  - 性能与内存指标前后对比。
- 编写 `Docs/ReleaseExceptions/<VERSION>.md`（如适用）。

### 5. 正式构建发布与官网同步 (Release & Site Deployment)
- 用于发布的公证候选包必须以正式通道构建（`package_release_dmg.sh` 会拒绝非 `stable` 通道的包，否则"关于"页会把正式版显示为"测试版本"）：
  ```bash
  AETHERROUTE_CANDIDATE_CHANNEL=stable AETHERROUTE_TEST_CORE_VARIANT=normal ./scripts/build_notarized_test_candidate.sh Config/Signing.json "<NOTARY_PROFILE>" <VERSION> <BUILD> outputs/notarized-candidate-<VERSION>-<BUILD>
  ```
- 执行纯净正式发布 DMG 打包（强制执行零测试说明校验，磁盘卷标统一为 `AetherRoute <VERSION>`，完成 Developer ID 签名、Apple 官方公证与装订）：
  ```bash
  ./scripts/package_release_dmg.sh outputs/notarized-candidate-<VERSION>-<BUILD>/<CANDIDATE_DMG> Config/Signing.json "<NOTARY_PROFILE>" <VERSION> <BUILD> outputs/release-<VERSION>-<BUILD>
  ```
- 更新并签名 Sparkle 自动更新清单：
  ```bash
  ./scripts/generate_sparkle_appcast.sh outputs/release-<VERSION>-<BUILD>/<DMG_FILE>
  ```
- 提交 Git 变更、打对应版本 Tag，并推送到远端仓库：
  ```bash
  git commit -m "chore(release): 发布 v<VERSION> 正式版及 Appcast"
  git tag -a "v<VERSION>" -m "Release v<VERSION>"
  git push origin main --tags
  ```
- 准备包含官方双语元数据隐藏块的 Release 说明文件（`<NOTES_FILE>` 末尾必须包含 `<!-- aethernative ... -->` 结构化配置，用于同步到新官网 `https://www.aethernative.com`）。
- 发布 GitHub Release 并上传公证纯净 DMG 及校验文件（发布后 GitHub Actions 自动触发 `aethernative-sync.yml` 通知新官网部署更新）：
  ```bash
  gh release create "v<VERSION>" <DMG_PATH> <SHA256SUMS_PATH> --title "v<VERSION>" --notes-file <NOTES_FILE>
  ```

## 每次发布后的磁盘清理（必须执行）
- 构建前检查本项目产物占用及磁盘可用空间；空间不足先清理已确认可删除的旧产物，不能继续堆积。
- 每次新版本发布并完成适用平台的签名公证、官网更新、应用内升级与功能验收后，必须清理本项目之前版本遗留的可再生成构建产物及测试临时文件，不能只发布不收尾，避免持续占用磁盘。
- 清理范围包括已确认归属本项目且不再使用的旧预览包、解包后的旧测试 App、旧构建中间产物、临时 DMG 挂载目录、重复下载和解压副本、测试夹具、测试进程及 VM 内对应临时文件。测试产生的偏好设置须恢复，临时挂载须卸载。仍在使用的构建和其他任务的环境不得清理。
- 清理前必须列出具体路径并检查实际内容、归属及用途，记录占用；禁止仅凭名称、版本号或宽泛通配符递归删除。用户已授权上述明确的项目构建与测试临时文件清理，无需逐次重复确认；归属或保留需求不明确的文件先确认。
- 源码、Git 历史、历版正式安装包与正式源码归档、签名及公证记录、必要的验收报告和发布截图必须保留；签名密钥、凭据、用户数据和其他项目文件禁止清理。删除旧构建目录时必须先将其中需要保留的正式产物及证据妥善归档并验证，不能整目录直接删除。
- 应用内升级验收所需的上一正式版本基线必须保留到升级测试通过；之后可以清理其解包和安装的测试副本，但保留正式安装包以便回归及回滚。当前版本仅保留必要的预览包、正式发布产物和验收证据，去除重复临时副本。
- 发布收尾必须验证保留产物可用、临时挂载已卸载、测试进程已退出、VM 环境已恢复，并报告清理路径、实际释放空间及当前磁盘剩余空间。未完成清理及验证，不得宣称发布流程全部完成。项目发布清理授权不改变应用面向用户的清理确认与安全规则。
