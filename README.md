# Relay Workspace

An agent-first work journal for Mac, iPhone and iPad. Built with SwiftUI, Foundation and UserNotifications. 本项目使用 MIT 许可证。

Relay 把方向、已排期需求和独立 Task 放在同一棵树上。探索或 To Do 可以先按主题收集，决定投入时再转成需求。成员可以在每个事项中承担不同角色，状态支持自由填写。概览根据暂停记录、计划节点和交付回执列出需要回看的线索。

## 安装

下载预编译 Mac 版时，在最近成功的 [Apple clients 构建](https://github.com/wang-sy/relay-workspace/actions/workflows/apple.yml)中打开 Artifacts，选择 **Relay-Workspace-macOS**。解压后打开磁盘映像，把应用拖入“应用程序”。预览安装包采用 ad hoc 签名，未做 Developer ID 公证。

- **Mac** 需要 macOS 14 或更高版本和 Swift 5.9+ 工具链。在项目根目录运行 `Scripts/package-mac.sh`。打开 `dist/Relay-Workspace-macOS.dmg`，将 Relay Workspace 拖入“应用程序”。本机构建采用 ad hoc 签名。要同时生成 Apple Silicon 和 Intel 二进制，可以设置 `RELAY_ARCHS="arm64 x86_64"`。
- **iPhone 和 iPad** 需要 iOS / iPadOS 17 或更高版本。用完整 Xcode 打开 `Relay.xcodeproj`，选择 `Relay` scheme 和对应的模拟器，运行即可。装到自己的真机时，在 Signing & Capabilities 选择自己的开发团队，必要时换成团队可用的 Bundle ID。这个工程使用同一套原生主从导航，窄屏逐层进入，宽屏显示侧栏。
- **Mac 开发** 也可以运行同一个 Xcode scheme。运行 `swift test` 验证核心逻辑。CI 另行构建 Mac 应用，在 iPhone 和 iPad 模拟器安装、启动并保留截图。

## 工作空间和多设备

首次打开 Mac 或移动客户端时，本地工作空间含有一组虚构示例。在“工作空间”里选择任一可写的专用文件夹即可使用自己的数据。在 Apple 设备间共享时，在访达和“文件”中将同一个 iCloud Drive 文件夹共享给成员，并让每台设备在应用中选择这个文件夹。文件夹共享权限由存储提供方控制。

每次写入都会在所选文件夹的 `RelayEvents` 下增加一条带 UUID 的 JSON 记录。客户端前台刷新时读取更新。各次披露独立存储，并按逻辑序号、请求 ID 确定性重放。并发操作造成无法应用的记录时，“工作空间”显示冲突记录。不同设备各自的默认本地文件夹彼此独立。

本版使用本地成员标签做署名和提醒匹配。它不提供企业 SSO 或经验证的团队身份。成员标签、会话名和记录内容将与所选文件夹的成员共享。

## 本地 Agent

Mac 应用同时附带 `relay` 命令。应用的“工作空间”中可以复制包含当前目录和成员标签的 Codex 接入命令。也可以手工在终端运行以下命令。使用共享文件夹时，在 `mcp` 前添加 `--workspace "/path/to/shared-folder"`。按需通过环境变量 `RELAY_ACTOR` 和 `RELAY_AGENT` 指定署名与 Agent 名称。

```sh
relay_bin="/Applications/Relay Workspace.app/Contents/MacOS/relay"
codex mcp add relay -- "$relay_bin" mcp
# Claude Code
claude mcp add --transport stdio relay -- "$relay_bin" mcp
```

stdio MCP 提供 `relay_read` 和 `relay_apply`。直接通过 shell 调用时，`read`、`gaps` 返回 JSON，`apply` 从 stdin 读取一条写入。重复提交同一请求时使用相同的 requestID、成员、来源、会话和内容。新写入使用新的 UUID。时间字段采用 ISO 8601，例如 `2030-03-01T09:00:00Z`。

```sh
"$relay_bin" gaps
"$relay_bin" apply <<'JSON'
{
  "requestID": "2f4e7128-01a7-4c48-9e60-a195936249b1",
  "session": "first-use-research",
  "change": {
    "operation": "create", "itemID": "idea-offline-notes", "kind": "idea",
    "title": "观察离线记录如何接续", "category": "产品 / 用户研究",
    "members": [{"name": "River", "role": "现场访谈"}]
  }
}
JSON
```

| 动作 | 关键字段 |
| --- | --- |
| create | kind、title、itemID。需求的 parentID 指向方向，Task 的 parentID 指向需求。需求填写 start 和 end。 |
| update / promote | status、members、next 等按需提供。promote 保留探索 ID 和历史，并填写方向和计划周期。 |
| pause / resume / close | 记录暂停、恢复或收尾事实，可同时填写状态和说明。 |
| milestone / result | 计划日期 due 和内容 note。结果通过 reference 指向原计划事件 UUID。 |
| handoff / acknowledge | 交给 recipient 并填写 note。回应通过 reference 指向具体的交付事件。 |
| remind | due、recipient、note。指定当前暂停事件的 UUID 作为 reference 即可约定条件回看。 |

## 本地通知

在“提醒”里允许系统通知。应用读取与当前成员标签或全体成员（`*`）匹配的约定。普通定时提醒在客户端同步后交由系统调度，已经登记的提醒可在应用退出后送达。条件提醒在客户端运行并读到最新工作记录时核对原暂停事件，满足条件才投递，设备离线或应用关闭可能延迟。提醒会受系统授权、专注模式和文件同步进度影响。同一成员的每台启用设备分别处理本地通知。

## 目录

- `App/` 包含原生 SwiftUI 界面、文件夹选择和系统通知。
- `Sources/RelayCore/` 包含共享模型、工作记录和遗漏判断。
- `Sources/RelayCLI/` 包含 macOS CLI 与 stdio MCP 接口。
- `Tests/` 与 `Scripts/smoke-agent.py` 覆盖条件提醒、请求重试、层级与 Agent 读写。
