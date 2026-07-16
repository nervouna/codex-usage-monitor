# Codex Usage Monitor

一个原生 macOS 菜单栏 App，用于查看当前 ChatGPT 账号的 Codex 额度和 token 用量。

## 功能

- 菜单栏实时显示标准 Codex 7 天滚动额度的剩余百分比。
- 显示额度重置时间，以及其他模型（例如 Codex Spark）的独立额度。
- 显示过去 7/30 个完整自然日的总用量、日均用量和账号历史累计用量。
- 每 5 分钟自动刷新，支持手动刷新和开机启动。
- 刷新失败时保留最后一次成功数据并提示数据可能已过期。
- 标准 Codex 周额度进入新周期时发送本地通知，正文包含当前剩余、下次重置时间和过去 7 天用量。
- 每个额度周期首次降至 20% 或以下时提醒一次。

## 额度通知

更新后首次打开菜单弹窗时，App 会请求 macOS 通知权限。菜单中的“额度通知”开关默认开启，可随时关闭；如果系统权限被拒绝，可从菜单直接打开系统设置。

额度状态随每次成功刷新保存在本机。首次取得数据只建立检测基线，不会误报；后续即使 App 在重置期间退出，也能通过额度周期变化识别重置。检测沿用 5 分钟刷新间隔，跨设备使用可能导致通知略有延迟，通知会显示检测时的实际剩余比例。

## 前置条件

- macOS 14 或更高版本。
- 已安装 ChatGPT App 或 Codex CLI。
- Codex 已使用 ChatGPT 账号登录。

App 通过本机 `codex app-server --stdio` 调用实验性 JSON-RPC 接口，不会读取、复制或保存登录 token。该协议可能随 Codex 升级发生变化。

## 构建

```bash
xcodebuild \
  -project CodexUsageMonitor.xcodeproj \
  -scheme CodexUsageMonitor \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  build
```

构建产物位于 `.build/DerivedData/Build/Products/Debug/Codex Usage Monitor.app`。

运行测试：

```bash
xcodebuild \
  -project CodexUsageMonitor.xcodeproj \
  -scheme CodexUsageMonitor \
  -derivedDataPath .build/DerivedData \
  test
```

开机启动需要从 `.app` 包运行；直接运行内部可执行文件时，系统可能拒绝注册登录项。
