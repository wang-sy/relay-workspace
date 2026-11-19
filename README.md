# Relay Workspace

Relay 是一个面向 Agent 的团队工作日志。Mac、iPhone 和 iPad 使用 SwiftUI 原生客户端。独立的 TypeScript HTTP 服务保存团队记录，Codex 和 Claude Code 可以通过 Mac 自带的 CLI 或 stdio MCP 读写同一份数据。项目使用 MIT 许可证。

Mac、iPhone 和 iPad 提供只读看板。成员可以浏览、筛选和接收本地提醒。新增需求、记录进展、维护分类和启停自动化都由 Agent 通过 CLI 或 MCP 完成。

客户端有两个入口。打开「方向与需求」可切换树状图、甘特图和状态卡片，设备会记住上次选择。未来想法和待办放在「探索池」。Mac 和宽屏 iPad 使用侧栏，紧凑宽度使用底部标签栏。两个页面都可通过筛选查看「与我有关」的事项。

- **树状图**按方向展开需求，再按需展开任务。点名称进入详情，查看参与成员、时间线和交付历史。
- **甘特图**按周展示需求的起止时间和计划节点。可以前后翻周，点需求查看详情。
- **状态卡片**按事项实际填写的状态分组。卡住或等人接手的需求优先显示，并写出依赖对象和原因。需求自身的依赖优先，其次是任务上明确标为影响需求的依赖。尚未开工的需求显示计划开始日。当天收尾的需求和结果列在下方，次日收入「以往完成」。日期按设备的本地日历计算。

## 先在 Mac 上跑起来

后端使用 Node.js 24 或更高版本及 SQLite。从仓库根目录运行以下命令，保持终端中的服务运行。

```sh
cd server
npm ci
npm run build
npm start
```

打开 Mac 客户端。首次启动默认连接 `http://127.0.0.1:8731`。新的团队数据库为空，可以让 Agent 创建第一个方向或写入第一条探索。需要使用其他服务时，从工作空间菜单打开「工作空间设置」，点「切换工作空间」输入服务地址。连接成功后可直接进入「方向与需求」。Mac 的菜单位于侧栏底部，手机的菜单位于页面左上角。每台真机的回环地址都指向设备自身，iPhone 和 iPad 连接团队服务时使用设备可达的 HTTPS 地址。

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
| `RELAY_MEMBERS_JSON` | JSON 对象，以成员邮箱或昵称为键，值为含 `viewer` 与 `agent` 的对象，分别供看板和助手使用。兼容旧的单令牌字符串，按 Agent 凭据处理。每个令牌至少 24 个非空白字符，且互不相同。向其他成员开放服务时必须配置，包括把回环服务交给反向代理的情况。 |
| `RELAY_LOG_REQUESTS` | 设为 `1` 时记录读写路由和 HTTP 状态码。 |

每个成员都可以有一对凭据。看板使用 `viewer` 令牌，Agent 通过 `RELAY_TOKEN` 使用同一成员的 `agent` 令牌，或者在 Mac 的连接设置中保存 Agent 令牌供内置 CLI 通过 `--keychain` 读取。服务端按 Bearer 令牌确定记录作者。客户端界面始终只读，服务端拒绝查看令牌的每一种写入。团队令牌由部署者分发，本版尚未接入企业单点登录。

本机演示允许直接读取回环服务。服务启动时为当前端口生成私有写入凭据，保存为仅当前账户可读写的 `~/.relay/local-agents/<端口>.token`。同账户的 CLI 和 MCP 自动读取，原有助手配置可以继续使用。需要覆盖目录时给服务和助手设置相同的 `RELAY_LOCAL_AGENT_DIR`。演示模式的署名来自设备配置。

写接口要求 Agent 凭据与 `X-Relay-Client: agent`，新版 CLI 和 MCP 会自动携带。旧版客户端可以继续查看。接口验证调用凭据，持有人在终端手动运行 CLI 也拥有相同能力。

| HTTP 接口 | 行为 |
| --- | --- |
| `GET /healthz` | 服务健康状态。 |
| `GET /v1/workspace` | 支持 `If-None-Match`。带 `X-Relay-Types: open` 时返回完整的 `items`、`entries`、`definitions` 和 `conflicts`。旧版客户端继续读取内置类型的兼容视图。 |
| `POST /v1/events` | 提交 `requestID`、`source`、`change` 以及可选的 `session`。本机演示模式还需提供 `actor`。新事件返回 201，同一请求重试返回原事件及 200，复用 ID 提交不同内容返回 409。 |
| `GET /v1/functions`、`GET /v1/functions/:id` | 查看托管函数。详情含当前源码、版本和最近 30 次执行。 |
| `PUT /v1/functions/:id`、`PATCH /v1/functions/:id` | 发布定义或修改启停状态。两者均使用成员身份和 `expectedRevision`。 |

## 已有本地工作空间

在「工作空间设置」点「切换工作空间」，选择「本地记录」，即可打开此设备上的记录或选取已有文件夹。此前明确选择过共享文件夹的设备会沿用原选择。切换到服务时，应用不会自动上传旧文件。部署者可以将完整下载的旧 `RelayEvents` 目录导入一个空数据库，保留原事件 ID、时间和署名。出现冲突会回滚整批导入。

```sh
# 在 server/ 目录中执行，使用与服务相同的 RELAY_DB
npm run import-journal -- "/path/to/workspace/RelayEvents"
```

需要演示数据时，可以先用 `relay --workspace /path/to/empty-demo sample` 在新的目录中生成虚构示例，再将其中的 `RelayEvents` 导入空数据库。

## 本地 Agent

Mac 应用包含 `relay` CLI。从侧栏底部的成员菜单打开「工作空间设置」→「连接助手」，选 Codex 或 Claude Code，再点「添加到…」。Relay 用已安装的助手命令行工具为当前看板添加个人配置。「工作空间」会显示已为此看板配置的助手。新开一个助手对话，可以问「团队有哪些需求在等人接手？」。iPhone 和 iPad 连接同一团队服务后也能看到助手写入的进展。

「手动设置」可复制适配当前工作空间和署名的终端命令。下面是本机服务的示例。

```sh
relay_bin="/Applications/Relay Workspace.app/Contents/MacOS/relay"
codex mcp add relay -- "$relay_bin" --server http://127.0.0.1:8731 mcp
claude mcp add --scope user --transport stdio relay -- "$relay_bin" --server http://127.0.0.1:8731 mcp
```

CLI 和 MCP 默认连接本机服务，`--server` 或 `RELAY_SERVER_URL` 可以指定团队地址。令牌可通过运行进程的 `RELAY_TOKEN` 环境变量提供，或加上 `--keychain` 读取应用为该服务保存的令牌。要访问文件工作空间，显式传入 `--workspace DIRECTORY`。在本机演示或文件模式下可以设置 `RELAY_ACTOR` 指定署名，`RELAY_AGENT` 用于记录工具来源。

stdio MCP 提供 `relay_read` 和 `relay_apply`。用 `relay board` 或 `relay_read` 的 `{"scope":"board"}` 读取团队当前需要关注的需求、等待对象和当日完成结果。「状态卡片」复用这些进展信号，并展示其他排期和历史需求。`read` 和 `gaps` 分别返回完整记录和待回看信号，`apply` 从 stdin 读取一条写入。重复提交同一请求时使用相同的 requestID、成员、来源、会话和内容。新写入使用新的 UUID。时间字段采用 ISO 8601，例如 `2030-03-01T09:00:00Z`。

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

## 让 Agent 定义团队的工作方式

Agent 可以直接用新名字创建事项、记录事件、填写状态、成员角色和探索分类。比如创建一个「访谈」，加上「访谈对象」字段，稍后记录一次「已回访」事件。另一个 Agent 用 `relay types` 或 `relay_read` 的 `scope: "types"` 就能查到工作空间用过的名字、字段和已登记的模板。成员打开详情即可看到相应的属性和事件数据。

需要把约定共享给团队时，Agent 用 `relay_apply` 写入 `operation: "defineType"`，以 `itemID` 为类型名，并填写 `definition` 和 `expectedRevision`。首次定义的版本号传 0，修改时传读到的版本号和完整的新定义。重复发送同一请求时沿用原 `requestID`。

| 团队可以定义 | 在 Relay 中的用法 |
| --- | --- |
| 事项 `item` | 可以声明展示名称、默认状态、字段和可选的 `base`。例如「实验」沿用 `idea` 就进入探索池。独立事项可以自由嵌套，出现在树状图和状态卡片中，填写起止日期后也会出现在甘特图。已经使用的类型保留原有层级规则。 |
| 事件 `event` | 直接把业务动作写进 `operation`。用 `payload` 保存本次发生了什么，用 `fields` 更新事项的当前属性。顶层属性设为 `null` 可移除该属性，历史事件保留原值。 |
| 分类、状态、角色 | `category`、`status`、`role` 都能随写随用，也可以先登记名称、显示名和说明。探索池会显示预先创建的空分类，支持「产品 / 用户研究」这样的分类路径。 |
| 触发器 `trigger` | 为事件、指定时间或 cron 起一个业务名称。发布函数时用这个名称就能订阅。直接使用一个未登记的名称会订阅同名事件。函数保留发布时的触发条件，重新发布可采用新版模板。 |

字段可以保存字符串、数字、布尔值、数组和嵌套对象。登记了类型的字段会在写入时校验，额外的字段仍可直接使用。事项字段和事件载荷分别支持 64 KiB、最多 16 层。需要精确保存超出 JavaScript 安全整数范围的编号时使用字符串。

仓库中的示例会创建「产品 / 用户研究」分类、定义「用户实验」及其「样本量」，并写入一次带通过率的「复验通过」。可从仓库根目录在临时工作空间运行。

```sh
demo=$(mktemp -d)
while IFS= read -r change; do
  printf '%s\n' "$change" | relay --workspace "$demo" apply
done < Examples/experiment.jsonl
relay --workspace "$demo" types
```

Agent 将函数部署到服务时，可用 `{"kind":"实验复核"}` 订阅示例中的事件。函数通过 `ctx.item.fields.sampleSize` 获取当前样本量，通过 `ctx.event.change.payload.passRate` 获取这次复验的通过率。文件工作空间可保存这些约定，执行托管函数需要 Relay 服务。

## 服务端托管函数

可以让 Agent 设置「事项暂停三天后，如果还在等人，就提醒负责人」。Agent 用 `relay_functions` 发布 JavaScript，Relay 服务负责计时、读取当时的事项并执行。发布者退出 Codex、关闭客户端或让自己的电脑休眠后，常驻服务器仍会工作。Mac、iPhone 和 iPad 的成员菜单都有「服务端自动化」，可查看谁发布了函数、何时运行、写了几条记录，以及当前启停状态。暂停和恢复交给 Agent。

将团队的 Node 服务作为常驻进程运行，给 `RELAY_DB` 配置持久目录。函数源码、触发时间、运行记录和事项共用这份 SQLite 数据库。服务重启后会接续到期的任务；错过多个 cron 周期时补跑一次，再转到下一个时间点。

在仓库根目录可发布同一份示例。新函数使用版本 0；修改时先读取当前版本，版本冲突返回 409。

```sh
relay functions deploy < Examples/pause-review.json
relay functions list
relay functions get pause-review
relay functions disable pause-review 1
relay functions enable pause-review 2
```

| 触发条件 | 例子 |
| --- | --- |
| 指定时间 `at` | `{"kind":"at","at":"2030-06-03T09:00:00+08:00","itemID":"REQ-02"}` |
| 周期 `cron` | `{"kind":"cron","expression":"0 9 * * 1-5","timezone":"Asia/Shanghai"}` |
| 事项事件 `event` | `{"kind":"event","operation":"pause","delaySeconds":259200}` |

`code` 是同步 JavaScript 函数体。上下文 `ctx` 包含发布人 `actor`、实际执行时间 `now`、原定时间 `scheduledAt`、函数 ID 与版本。事件触发时，`ctx.event` 是原始事件，`ctx.item` 是执行时的最新事项。定时触发可指定 `itemID`，省略后可用 `ctx.items` 查看工作空间事项。示例会比对当前 `pauseID` 与原事件 ID，已恢复或重新暂停的事项会跳过。事件订阅从发布后新写入的事件开始生效。MCP 工具支持 `list`、`get`、`deploy`、`enable` 和 `disable`，文件工作空间沿用原有读写工具。

返回 `[]` 表示跳过，返回最多 8 个标准 `change` 对象即可写进工作日志。服务会校验整批变更，在一个事务中提交变更和运行结果，并记下发布人、函数 ID 和运行 ID。函数写出的事件不会再触发其他函数。改版或暂停会取消旧版本待处理的执行。代码错误会出现在运行记录里；进程故障或所读事项并发变化时最多尝试三次。

每次调用都在独立子进程中的 QuickJS WebAssembly 环境执行，只接收工作空间数据；主机文件、Node API、网络和服务凭据对函数不可见。源码上限 32 KiB，输入 256 KiB，输出 32 KiB。解释器配置 8 MiB 内存及 150 毫秒执行预算，外层进程另有 4 秒截止时间。[QuickJS 运行时](https://github.com/justjake/quickjs-emscripten)

## 本地通知

从工作空间菜单进入「提醒」，可以查看回看约定并允许系统通知。普通提醒在客户端同步后由系统调度。条件提醒会在客户端运行并读到最新记录时核对原暂停事件，离线或应用关闭可能延迟。提醒只匹配当前成员或全体成员（`*`）。同一成员的各台设备分别处理本地通知。

托管函数可以返回 `remind` 将提醒写进团队日志。服务端执行完成后，成员会在设备下一次同步时收到符合条件的提醒。系统横幅仍取决于设备的通知授权和同步时机。

## 开发与验证

- `server/` 包含 TypeScript API、SQLite 存储、导入工具和接口测试。在此目录运行 `npm ci && npm test`。
- `App/` 包含共享 SwiftUI 界面和设备通知。`Sources/RelayCore/` 包含事件模型、HTTP 客户端及文件工作空间。
- `Sources/RelayCLI/` 包含 CLI 和 stdio MCP。在完整 Xcode 环境中运行 `swift test`。构建后，`python3 Scripts/smoke-agent.py .build/debug/relay --service` 会启动临时后端并验证跨进程写入和读取。
- GitHub Actions 测试 TypeScript 服务、构建三端客户端，在 iPhone 和 iPad 模拟器中确认客户端读到服务快照，并打包通用 Mac 安装包。
