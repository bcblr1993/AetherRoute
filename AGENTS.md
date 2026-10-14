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
- 运行 12 种协议的真实互通门禁（`test.sh` 只校验运行脚本文本，不会真正连接）。首次运行先下载并校验第三方服务端（sing-box、shadow-tls、Xray、Mihomo，均按固定 SHA-256 校验；WireGuard 服务端从源码编译），缓存在已被忽略的 `build/interop-tools`：
  ```bash
  ./scripts/fetch_interop_tools.sh
  ./scripts/test_protocol_interop_all.sh
  ```
  门禁编译与发布一致的 release 引擎，在本机回环上逐一对接 sing-box 矩阵（24 个用例）、VLESS REALITY、WireGuard、ShadowQUIC 与 OpenSSH；每个用例都检查 2 MiB 双向传输、空闲后复用、8 包 UDP（重复送达即失败），TLS 用例还必须通过证书指纹固定（Hysteria2、TUIC 另测 `ca-str` 自定义 CA）、拒绝错误指纹，并在开启证书校验时拒绝不受信任的证书（服务端证书由 `Tests/Interop/make-test-pki.sh` 生成的临时 CA 签发）。五项必须全部 PASS，日志与汇总在 `outputs/interop-<时间>/`。该门禁曾发现 Shadowsocks UDP 重复发包与 SSH 空闲 5 秒断开（1.1.7 修复）。
  - 每次发布都必须运行；`Core/Engine` 有任何改动时必须在提交前运行。
  - 修改 `interop_tests.rs` 后同步 `Config/ProtocolCoreEvidence.json`（`coreCommit`、`interopTestsSHA256`、`interopCases`）与 `Config/ProtocolReleaseMatrix.json`，并以 `./scripts/verify_protocol_matrix.sh` 校验。
  - REALITY 用例的 Xray 服务端每次握手都会访问真实的 www.cloudflare.com，本机网络繁忙时单轮会慢 5–10 秒；单项超时先单独重跑该项确认，不要放宽其他用例。
  - 排查时可用 `AETHER_INTEROP_CASES=名称,名称` 只跑部分矩阵用例，`AETHER_INTEROP_PROFILE=debug` 加快编译。

> **第 2 步与第 3 步并行自动化执行（Mandatory SOP）**：QA 候选包构建与双端验证现已通过并行流水线脚本完全自动化：
> ```bash
> ./scripts/run_release_acceptance_parallel.sh <VERSION> <BUILD>
> ```
> 该脚本会自动以生产级正常核心（`AETHERROUTE_TEST_CORE_VARIANT=normal`）构建 QA 候选包，并在后台并发驱动：
> 1. **Tart 虚拟机矩阵验收**（包含 6 维引擎与路由模式，集成透明代理 4 项强化门禁）；
> 2. **物理真机环境与 UI 性能门禁**（包含 `test_remote_arm64.sh fast` 与 `test_ui_performance_gate.sh`）。
> 优化后 direct 模式自动短路 50 秒空闲盲等，整体测试时长由过去近 45 分钟大幅压降至约 10~15 分钟，且绝不污染宿主机网络与配置。

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
- 矩阵的每个组合还包含 **大请求上传检查**（`scripts/test_large_upload.sh`）：经代理向 `httpbin.org/post` 上传 2 MiB 随机数据，必须 HTTP 200 且完整送达。该检查防止出站协议在客户端写入快于节点上行时破坏分帧（曾因 VLESS Vision 帧长 u16 溢出，导致 Claude Code 等大上下文请求 `ECONNRESET`）。`tun` 与 `transparent` 都必须 PASS；`direct` 路由下若连小请求都不通记为 SKIP。
- **清理规范（Mandatory）**：
  - 测试完成后必须立即清理虚拟机内的安装包、解压临时目录及相关日志记录，保持 VM 干净。

### 3. 物理真机环境验证 (Remote Hardware Validation)
- 物理设备标准：`chenxu@100.64.0.3` (Apple Silicon Mac mini)。
- 运行远程自动化测试门禁：
  ```bash
  AETHERROUTE_ALLOW_REMOTE_GATE=YES ./scripts/test_remote_arm64.sh chenxu@100.64.0.3 fast
  ```
- 将构建包/测试用例无损同步至该物理机，在物理机上直接执行多场景协议与网络状态测试，并在该机器分析测试报告，确保 100% 通过。
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



