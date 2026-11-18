import Foundation

public enum Example {
  public static func entries(at now: Date) -> [Entry] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n - 7, to: today) ?? today }
    var events = [Entry]()
    @discardableResult func add(_ c: Change, _ when: Int, who: String = "River") -> UUID {
      let index = events.count + 1
      let id = UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", index))!
      events.append(
        Entry(
          id: id, sequence: index, time: day(when), actor: who, source: "示例 Agent",
          session: "onboarding-guide", change: c))
      return id
    }
    func item(
      _ id: String, _ kind: ItemKind, _ title: String, _ parent: String?, _ status: String,
      _ next: String, _ members: [Member], _ from: Int = 1, _ to: Int = 12
    ) {
      var c = Change(.create, id)
      c.kind = kind
      c.parentID = parent
      c.title = title
      c.status = status
      c.next = next
      c.members = members
      if kind == .requirement {
        c.start = day(from)
        c.end = day(to)
      }
      add(c, from)
    }
    item("DIR-01", .direction, "让第一次使用更顺畅", nil, "持续投入", "观察从第一次打开到做成第一件事的路径。", [])
    item("DIR-02", .direction, "让协作交付更清楚", nil, "持续投入", "把交接中的约定和结果放到同一处。", [])
    item(
      "REQ-01", .requirement, "第一次导入就能看到示例", "DIR-01", "小范围试用", "复核空文件和重复导入两类样本。",
      [Member("River", "定义首次成功"), Member("Jun", "导入实现")], 1, 11)
    item(
      "REQ-02", .requirement, "提供可复用的入门指南", "DIR-02", "草稿已交付", "用新成员的视角走一遍安装步骤。",
      [Member("Mira", "整理示例"), Member("River", "首次体验")], 2, 13)
    item("TASK-01", .task, "确认示例素材的公开范围", "REQ-02", "等待答复", "核对可公开素材的清单。", [Member("Jun", "外部对接")])
    item(
      "TASK-02", .task, "在空目录复测安装步骤", "REQ-02", "等待体验反馈", "从空目录验证指南的第一条命令。", [Member("River", "试用")]
    )
    var pause = Change(.pause, "TASK-01")
    pause.note = "素材清单已经准备好，仍在等公开范围的回复。"
    add(pause, 3, who: "Jun")
    var milestone = Change(.milestone, "REQ-01")
    milestone.due = day(6)
    milestone.note = "复核空文件导入样本"
    add(milestone, 3)
    var handoff = Change(.handoff, "TASK-02")
    handoff.recipient = "River"
    handoff.affectsRequirement = true
    handoff.note = "入门指南草稿已就绪，请从空目录复测。"
    add(handoff, 5, who: "Mira")
    var idea = Change(.create, "IDEA-01")
    idea.kind = .idea
    idea.title = "探索离线采集笔记"
    idea.category = "产品 / 现场体验"
    idea.status = "待探索"
    idea.note = "了解现场记录在没有网络时如何接续。"
    add(idea, 5)
    idea.itemID = "IDEA-02"
    idea.title = "汇总重复的构建失败"
    idea.category = "技术 / 内部提效"
    idea.note = "先取一组样本判断是否值得投入。"
    add(idea, 6, who: "Jun")
    item(
      "REQ-03", .requirement, "保存离线草稿", "DIR-01", "联调中", "验证断网后恢复编辑。",
      [Member("Jun", "开发")], 4, 12)
    item(
      "REQ-04", .requirement, "迁移旧账号", "DIR-02", "字段核对", "映射后导入历史记录。",
      [Member("Mira", "推进迁移")], 4, 12)
    var blocked = Change(.pause, "REQ-04")
    blocked.recipient = "Jun"
    blocked.note = "确认旧账号的映射规则。"
    add(blocked, 7, who: "Mira")
    item(
      "REQ-05", .requirement, "导出交付记录", "DIR-02", "联调中", "提供导出结果。",
      [Member("River", "交付")], 3, 7)
    var closed = Change(.close, "REQ-05")
    closed.note = "支持按需求导出交付记录，已上线。"
    add(closed, 7)
    return events
  }
}
