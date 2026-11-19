# Relay Workspace

Relay 是一个面向 Agent 的团队工作日志。Mac、iPhone 和 iPad 使用 SwiftUI 原生客户端。独立的 TypeScript HTTP 服务保存团队记录，Codex 和 Claude Code 可以通过 Mac 自带的 CLI 或 stdio MCP 读写同一份数据。项目使用 MIT 许可证。

「团队概览」每个需求占一行，显示方向、署名推进人和当前进展。卡住或等接手的需求排在前面，完成当天留在底部并显示具体结果。日期按查看设备的本地日历计算。次日仍可从侧栏「方向与需求」打开详情，查看任务、排期和交付历史；未来想法在「探索池」。

首页即时显示未恢复的暂停和未回应的交付。需求自身的依赖优先，其次是任务上明确标为影响需求的依赖。旧任务记录仍参与汇总，标为仅影响任务的记录留在详情。尚未到开始日、也没有实际进展的需求留在排期中。角色和状态可自由填写。

## 先在 Mac 上跑起来

后端使用 Node.js 24 或更高版本及 SQLite。从仓库根目录运行以下命令，保持终端中的服务运行。

```sh
cd server
npm ci
npm run build
npm start
```

打开 Mac 客户端。首次启动默认连接 `http://127.0.0.1:8731`。新的团队数据库为空，可以从客户端新建方向或让 Agent 写入第一条探索。需要使用其他服务时，打开侧栏「工作空间」，点「切换工作空间」输入服务地址。连接成功后可直接进入「团队概览」。每台真机的回环地址都指向设备自身，iPhone 和 iPad 连接团队服务时使用设备可达的 HTTPS 地址。

## 安装原生客户端

GitHub Actions 的成功构建提供 **Relay-Workspace-macOS** 安装包。下载并解压后，打开磁盘映像，把应用拖入“应用程序”。预览安装包采用 ad hoc 签名，尚未进行 Developer ID 公证。[Apple 客户端与后端构建](https://github.com/wang-sy/relay-workspace/actions/workflows/apple.yml)

- **Mac** 支持 macOS 14 或更高版本。可以在项目根目录运行 `Scripts/package-mac.sh` 编译安装包。设置 `RELAY_ARCHS="arm64 x86_64"` 可打包 Apple Silicon 和 Intel 两种架构。
- **iPhone 和 iPad** 支持 iOS / iPadOS 17 或更高版本。在 Xcode 中打开 `Relay.xcodeproj`，选择 `Relay` scheme 和目标设备。真机安装需要在 Signing & Capabilities 中设置自己的开发团队。

## 团队服务

每个服务实例管理一个工作空间。服务端在一次 SQLite 事务里校验变更、分配序号、保存事件并更新事项。所有客户端看到同一段历史。客户端在前台每五秒检查更新，未变化的快照通过 ETag 返回。断开连接时，已打开的客户端保留最近一次读到的内容并提示连接状态。

| 配置 | 用途 |
| --- | --- |
| `RELAY_HOST`、`RELAY_PORT` | 默认监听 `127.0.0.1:8731`。发布到团队网络时，把服务放在 HTTPS 反向代理之后。 |
| `RELAY_DB` | 默认写入工作目录下的 `data/relay.sqlite`。从 `server/` 用 npm 启动时为 `server/data/relay.sqlite`。 |
| `RELAY_MEMBERS_JSON` | JSON 对象，以成员邮箱或昵称为键、个人 Relay 令牌为值。每个令牌至少 24 个字符且互不相同。向其他成员开放服务时必须配置，包括把回环服务交给反向代理的情况。 |
| `RELAY_LOG_REQUESTS` | 设为 `1` 时记录读写路由和 HTTP 状态码。 |

本机演示模式采用设备填写的成员标签。团队模式下，客户端发送 `Authorization: Bearer <Relay 令牌>`，服务端按令牌确定记录作者，忽略请求声称的身份。所有成员拥有同样的读写权限。个人令牌由部署者通过环境或密钥管理器提供。应用将手动输入的 Relay 令牌保存到此设备的钥匙串。本版尚未接入企业单点登录。

| HTTP 接口 | 行为 |
| --- | --- |
| `GET /healthz` | 服务健康状态。 |
| `GET /v1/workspace` | 返回 `{viewer, workspace: {items, entries, conflicts}}`，支持 `If-None-Match`。 |
| `POST /v1/events` | 提交 `requestID`、`source`、`change` 以及可选的 `session`。本机演示模式还需提供 `actor`。新事件返回 201，同一请求重试返回原事件及 200，复用 ID 提交不同内容返回 409。 |

## 已有本地工作空间

在「工作空间」点「切换工作空间」，选择「本地记录」，即可打开此设备上的记录或选取已有文件夹。此前明确选择过共享文件夹的设备会沿用原选择。切换到服务时，应用不会自动上传旧文件。部署者可以将完整下载的旧 `RelayEvents` 目录导入一个空数据库，保留原事件 ID、时间和署名。出现冲突会回滚整批导入。

```sh
# 在 server/ 目录中执行，使用与服务相同的 RELAY_DB
npm run import-journal -- "/path/to/workspace/RelayEvents"
```

需要演示数据时，可以先用 `relay --workspace /path/to/empty-demo sample` 在新的目录中生成虚构示例，再将其中的 `RelayEvents` 导入空数据库。

## 本地 Agent

Mac 应用包含 `relay` CLI。打开侧栏「工作空间」→「连接助手」，选 Codex 或 Claude Code，再点「添加到…」。Relay 用已安装的助手命令行工具为当前看板添加个人配置。「工作空间」会显示已为此看板配置的助手。新开一个助手对话，可以问「团队有哪些需求在等人接手？」。iPhone 和 iPad 连接同一团队服务后也能看到助手写入的进展。

「手动设置」可复制适配当前工作空间和署名的终端命令。下面是本机服务的示例。

```sh
relay_bin="/Applications/Relay Workspace.app/Contents/MacOS/relay"
codex mcp add relay -- "$relay_bin" --server http://127.0.0.1:8731 mcp
claude mcp add --scope user --transport stdio relay -- "$relay_bin" --server http://127.0.0.1:8731 mcp
```

CLI 和 MCP 默认连接本机服务，`--server` 或 `RELAY_SERVER_URL` 可以指定团队地址。令牌可通过运行进程的 `RELAY_TOKEN` 环境变量提供，或加上 `--keychain` 读取应用为该服务保存的令牌。要访问文件工作空间，显式传入 `--workspace DIRECTORY`。在本机演示或文件模式下可以设置 `RELAY_ACTOR` 指定署名，`RELAY_AGENT` 用于记录工具来源。

stdio MCP 提供 `relay_read` 和 `relay_apply`。用 `relay board` 或 `relay_read` 的 `{"scope":"board"}` 读取与客户端首页相同的需求清单。`read` 和 `gaps` 分别返回完整记录和待回看信号，`apply` 从 stdin 读取一条写入。重复提交同一请求时使用相同的 requestID、成员、来源、会话和内容。新写入使用新的 UUID。时间字段采用 ISO 8601，例如 `2030-03-01T09:00:00Z`。

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
| pause / resume / close | 暂停时用 note 说明卡点，用 recipient 指明在等谁。需求收尾须在 note 写明完成结果。旧记录仍可导入。 |
| milestone / result | 计划日期 due 和内容 note。结果通过 reference 指向原计划事件 UUID。 |
| handoff / acknowledge | 交给 recipient 并填写 note。回应通过 reference 指向具体的交付事件。任务的 pause 和 handoff 可填 affectsRequirement，表示是否影响上级需求。 |
| remind | due、recipient、note。指定当前暂停事件的 UUID 作为 reference 即可约定条件回看。 |

## 本地通知

在“提醒”中允许系统通知。普通提醒在客户端同步后由系统调度。条件提醒会在客户端运行并读到最新记录时核对原暂停事件，离线或应用关闭可能延迟。提醒只匹配当前成员或全体成员（`*`）。同一成员的各台设备分别处理本地通知。

## 开发与验证

- `server/` 包含 TypeScript API、SQLite 存储、导入工具和接口测试。在此目录运行 `npm ci && npm test`。
- `App/` 包含共享 SwiftUI 界面和设备通知。`Sources/RelayCore/` 包含事件模型、HTTP 客户端及文件工作空间。
- `Sources/RelayCLI/` 包含 CLI 和 stdio MCP。在完整 Xcode 环境中运行 `swift test`。构建后，`python3 Scripts/smoke-agent.py .build/debug/relay --service` 会启动临时后端并验证跨进程写入和读取。
- GitHub Actions 测试 TypeScript 服务、构建三端客户端，在 iPhone 和 iPad 模拟器中确认客户端读到服务快照，并打包通用 Mac 安装包。
