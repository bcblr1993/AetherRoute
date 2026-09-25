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

### 2. Tart 虚拟机矩阵自动化测试与清理 (VM Matrix Acceptance)
- 虚拟机名称标准：`aether-diag-1434`（本地 Tart VM）。
- 构建 QA 自动化测试候选包：
  ```bash
  ./scripts/build_signed_local_test_candidate.sh Config/Signing.json <VERSION> <BUILD> outputs/qa-candidate-<VERSION>-<BUILD>
  ```
- 运行 6 维网络矩阵与生命周期测试：
  ```bash
  ./scripts/test_vm_acceptance_matrix.sh outputs/qa-candidate-<VERSION>-<BUILD>/<ZIP_FILE> aether-diag-1434 outputs/vm-acceptance-<VERSION>-<BUILD>
  ```
- **清理规范（Mandatory）**：
  - 测试完成后必须立即清理虚拟机内的安装包、解压临时目录及相关日志记录，保持 VM 干净。

### 3. 物理真机环境验证 (Remote Hardware Validation)
- 物理设备标准：`chenxu@100.64.0.3` (Apple Silicon Mac mini)。
- 运行远程自动化测试门禁：
  ```bash
  AETHERROUTE_ALLOW_REMOTE_GATE=YES ./scripts/test_remote_arm64.sh chenxu@100.64.0.3 fast
  ```
- 将构建包/测试用例无损同步至该物理机，在物理机上直接执行多场景协议与网络状态测试，并在该机器分析测试报告，确保 100% 通过。

### 4. 版本迭代与 CHANGELOG 维护
- 依据语义化版本推进（如当前版本至下一版本）。
- 完整编写 `CHANGELOG.md`，包含：
  - 本次修复与优化内容说明；
  - 虚拟机 6 维矩阵与物理硬件测试验证结论；
  - 性能与内存指标前后对比。
- 编写 `Docs/ReleaseExceptions/<VERSION>.md`（如适用）。

### 5. 正式构建发布与官网同步 (Release & Site Deployment)
- 执行正式公证发布构建：
  ```bash
  ./scripts/release.sh Config/Signing.json "<NOTARY_PROFILE>" <VERSION> <BUILD> <OUTPUT_DIR>
  ```
- 更新并签名 Sparkle 自动更新清单：
  ```bash
  ./scripts/generate_sparkle_appcast.sh <DMG_PATH>
  ```
- 提交 Git 变更、打对应版本 Tag，并推送到远端仓库：
  ```bash
  git commit -m "chore(release): 发布 v<VERSION> 正式版及 Appcast"
  git tag -a "v<VERSION>" -m "Release v<VERSION>"
  git push origin main --tags
  ```
- 准备包含官方双语元数据隐藏块的 Release 说明文件（`<NOTES_FILE>` 末尾必须包含 `<!-- aethernative ... -->` 结构化配置，用于同步到新官网 `https://www.aethernative.com`）。
- 发布 GitHub Release 并上传公证 DMG 及校验文件（发布后 GitHub Actions 自动触发 `aethernative-sync.yml` 通知新官网部署更新）：
  ```bash
  gh release create "v<VERSION>" <DMG_PATH> <SHA256SUMS_PATH> --title "v<VERSION>" --notes-file <NOTES_FILE>
  ```


