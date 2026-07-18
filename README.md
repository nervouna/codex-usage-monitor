# Codex Usage Monitor

一个原生 macOS 菜单栏 App，用于查看当前 ChatGPT 账号的 Codex 额度和 token 用量。

## 功能

- 菜单栏实时显示标准 Codex 7 天滚动额度的剩余百分比。
- 显示额度重置时间，以及其他模型（例如 Codex Spark）的独立额度。
- 显示过去 7/30 个完整自然日的总用量、日均用量和账号历史累计用量。
- 每 5 分钟自动刷新，支持手动刷新和开机启动。
- 刷新失败时保留最后一次成功数据并提示数据可能已过期。
- 实际观察到标准 Codex 周额度从非 100% 回到 100% 时发送本地通知，正文包含当前剩余、下次重置时间和过去 7 天用量。
- 每个额度周期首次降至 20% 或以下时提醒一次。

## 额度通知

更新后首次打开菜单弹窗时，App 会请求 macOS 通知权限。菜单中的“额度通知”开关默认开启，可随时关闭；如果系统权限被拒绝，可从菜单直接打开系统设置。

额度状态随每次成功刷新保存在本机。首次取得数据只建立检测基线，不会误报；后续只有实际观察到剩余额度从非 100% 回到 100% 时才会通知。如果 App 未观察到 100% 状态，则不会补发重置通知。检测沿用 5 分钟刷新间隔，跨设备使用可能导致通知略有延迟。

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

## 打包

统一使用 `scripts/package.sh` 生成 Release universal ZIP。先运行 `--dry-run` 查看 Git 门禁、当前和下一个 build number、产物路径及外部操作；dry run 不修改文件、不提交、不推送，也不上传公证请求。

```bash
./scripts/package.sh adhoc --dry-run
./scripts/package.sh signed --dry-run
NOTARYTOOL_PROFILE=codex-usage-monitor ./scripts/package.sh notarized --dry-run
```

确认预检信息后，再执行对应命令：

```bash
./scripts/package.sh adhoc
./scripts/package.sh signed
NOTARYTOOL_PROFILE=codex-usage-monitor \
  ./scripts/package.sh notarized --confirm-publish
```

- `adhoc`：使用 ad hoc 签名，适合本机验证。允许脏工作区，会把未提交内容打入 App；build number 修改保留在工作区，不自动提交。
- `signed`：使用 Developer ID Application 签名，适合分享试用，但不代表已通过 Gatekeeper 公证。要求工作区完全干净；测试通过后只提交 build-number 修改，不自动 push。只有一个可用身份时自动选择；有多个身份时，通过 `DEVELOPER_ID_APPLICATION` 和可选的 `DEVELOPMENT_TEAM` 显式指定。
- `notarized`：用于正式发布。要求工作区完全干净、当前分支为 `main`，且开始时本地 `main` 与最新 `origin/main` 完全一致。脚本测试通过后提交 build-number 修改并 push，再提交 Apple 公证、装订 ticket 并通过 Gatekeeper 验证。正式执行必须显式提供 `--confirm-publish`。

`signed` 和 `notarized` 会在 build 自增前运行完整 XCTest；测试失败不会消耗 build number。build 提交一旦创建，即使后续构建或公证失败也会保留，不应回滚或复用。脚本不会创建 Git tag、GitHub Release，也不会修改 marketing version。

公证凭据只应保存在 Keychain 中。可以在本机交互式创建 profile，不能把 Apple ID 密码或 app-specific password 写入仓库：

```bash
xcrun notarytool store-credentials codex-usage-monitor
```

构建中间文件只写入 `.build/staging/`。所有验证通过后，最终 ZIP 才会移动到 `.build/releases/`，文件名格式为：

```text
Codex-Usage-Monitor-macOS-universal-<adhoc|signed|notarized>-YYYY-MM-DD-build-N.zip
```
