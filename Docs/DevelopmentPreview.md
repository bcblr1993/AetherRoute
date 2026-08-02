# AetherRoute 开发预览包

此 DMG 仅用于界面、交互、国际化和窗口体验验收，不是生产发布版。

- 仅包含 Apple Silicon (`arm64`) 程序。
- 使用本地 ad-hoc 签名，未经过 Developer ID 签名或 Apple 公证。
- 构建时移除了 Network Extension 权限；连接、TUN 和透明代理不能用于真实流量。
- 为允许无 Team ID 的 ad-hoc 内嵌 Framework 启动，预览主程序仅在此构建中关闭了
  Hardened Runtime 的 Library Validation；正式版禁止使用此权限。
- 请勿将此包对外发布、销售或当作网络客户端使用。
- 可以安全检查主页面、设置页面、语言切换、窗口缩放、按钮状态、关于页面和开源许可。
- 可以添加、编辑、切换和删除单个节点，用于检查表单校验和界面交互；配置只保存在
  当前预览进程的内存中，退出应用后自动清空，不访问正式版的 Keychain 或 App Group。
- 可以从用户明确提供的 HTTPS 订阅地址执行一次受大小、重定向和内容校验约束的下载；
  可用节点会导入当前预览进程的内存，无效节点会跳过并显示数量，失败原因会显示在订阅窗口。
  此功能只验证订阅兼容性，不会启动 Network Extension、TUN、透明代理或更改系统网络。
- 主连接按钮会明确显示“仅供预览”，并说明该构建不能启用系统路由。真实连接要求主程序和
  两个 Network Extension 使用匹配的 Developer ID 身份、权限与描述文件完成签名。
- 预览包的技术标识使用 `com.aetherroute.preview`；作者姓名只保留在关于页面和署名元数据中，
  不作为产品或包标识。

正式版仍必须通过 Developer ID、Network Extension provisioning profiles、Apple 公证、
24 小时长稳、Instruments 性能及签名后双引擎真机测试。
