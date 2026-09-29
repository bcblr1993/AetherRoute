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

> **第 2 步与第 3 步并行执行**：QA 候选包构建完成后，立即在后台同时启动虚拟机矩阵与物理真机门禁，不要串行等待。两者使用不同机器与目录，互不影响。注意：
> - 启动前先把引擎静态库与许可证清单恢复为正常版（QA 候选包构建会留下诊断版核心，真机门禁会因 `protocol evidence SHA-256 mismatch` 失败）；
> - 真机门禁结束时会重新核对本机源码清单，两者运行期间**不得修改任何受跟踪文件**；需要随发布提交的文档改动（版本号、CHANGELOG、例外说明、本文件）应在启动前完成；
> - 物理真机只能加载已公证的系统扩展，真机安装使用公证候选包（`build_notarized_test_candidate.sh`），本地 QA 包仅用于开启了开发者模式的虚拟机。

### 2. Tart 虚拟机矩阵自动化测试与清理 (VM Matrix Acceptance)
- 虚拟机名称标准：`macos27`（本地 Tart VM，统一使用；不再使用 `aether-diag-1434`）。
- 构建 QA 自动化测试候选包：
  ```bash
  ./scripts/build_signed_local_test_candidate.sh Config/Signing.json <VERSION> <BUILD> outputs/qa-candidate-<VERSION>-<BUILD>
  ```
- 运行 6 维网络矩阵与生命周期测试：
  ```bash
  ./scripts/test_vm_acceptance_matrix.sh outputs/qa-candidate-<VERSION>-<BUILD>/<ZIP_FILE> macos27 outputs/vm-acceptance-<VERSION>-<BUILD>
  ```
- 矩阵的每个"引擎 × 路由"组合都包含 **空闲 keep-alive 复用检查**（`scripts/test_idle_keepalive_reuse.sh`，由 `test_runtime_acceptance.sh` 调用）：同一条 TLS 连接空闲 50 秒后再次请求必须成功。`tun` 与 `transparent` 两个引擎都必须 PASS，任一 FAIL 即阻断发布。
- `transparent` 引擎的组合还包含 **SNI 目标恢复检查**（`scripts/test_transparent_sni_recovery.sh`）：用 `curl --connect-to` 把 `www.apple.com` 故意拨到无关 IP（默认 `1.1.1.1`），必须按 ClientHello 的 SNI 转发并通过证书校验。该检查防止透明代理再次按应用自行解析出的（被污染的）IP 转发，曾导致 Chrome 无法打开 Google。FAIL 即阻断发布；`tun` 引擎记为 SKIP。
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

### 4. 版本迭代与 CHANGELOG 维护
- 依据语义化版本推进（如当前版本至下一版本）。
- 完整编写 `CHANGELOG.md`，包含：
  - 本次修复与优化内容说明；
  - 虚拟机 6 维矩阵与物理硬件测试验证结论；
  - 性能与内存指标前后对比。
- 编写 `Docs/ReleaseExceptions/<VERSION>.md`（如适用）。

### 5. 正式构建发布与官网同步 (Release & Site Deployment)
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



