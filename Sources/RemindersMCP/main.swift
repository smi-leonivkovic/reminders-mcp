// reminders-mcp — Apple Reminders MCP server in pure Swift (EventKit), no dependencies.
import EventKit
import Foundation

let serverName = "reminders-mcp"
let store = EKEventStore()

func ensureAccess() throws {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if status == .fullAccess { return }
    if status == .notDetermined {
        let granted: Bool? = waitFor { done in store.requestFullAccessToReminders { ok, _ in done(ok) } }
        if granted == true { return }
    }
    throw ToolError("Reminders access denied. Allow it in System Settings → Privacy & Security → Reminders.")
}

// MARK: - Helpers

func lists() -> [EKCalendar] { store.calendars(for: .reminder) }

func findList(_ key: String) throws -> EKCalendar {
    let k = key.lowercased()
    if let l = lists().first(where: { $0.calendarIdentifier == key || $0.title.lowercased() == k }) { return l }
    throw ToolError("Reminder list '\(key)' not found. Available: \(lists().map(\.title).joined(separator: ", "))")
}

func fetch(_ predicate: NSPredicate) -> [EKReminder] {
    (waitFor { done in _ = store.fetchReminders(matching: predicate) { done($0 ?? []) } }) ?? []
}

func reminder(_ id: String) throws -> EKReminder {
    guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw ToolError("Reminder '\(id)' not found") }
    return r
}

/// "YYYY-MM-DD" (date only) or "YYYY-MM-DD HH:MM" → components (+ whether a time was given).
func parseDue(_ s: String) throws -> (DateComponents, Bool) {
    let parts = s.replacingOccurrences(of: "T", with: " ").split(separator: " ")
    let d = parts.first?.split(separator: "-").compactMap { Int($0) } ?? []
    guard d.count == 3 else { throw ToolError("Invalid due '\(s)', expected YYYY-MM-DD or YYYY-MM-DD HH:MM") }
    var c = DateComponents(calendar: .current, timeZone: .current, year: d[0], month: d[1], day: d[2])
    if parts.count > 1 {
        let t = parts[1].split(separator: ":").compactMap { Int($0) }
        guard t.count >= 2 else { throw ToolError("Invalid time in '\(s)', expected HH:MM") }
        c.hour = t[0]
        c.minute = t[1]
        return (c, true)
    }
    return (c, false)
}

func parsePriority(_ s: String) -> Int? {
    switch s.lowercased() {
    case "high", "1", "!!!": return 1
    case "medium", "5", "!!": return 5
    case "low", "9", "!": return 9
    case "none", "0": return 0
    default: return nil
    }
}

func priorityLabel(_ p: Int) -> String {
    switch p {
    case 1...4: return "!!! high"
    case 5: return "!! medium"
    case 6...9: return "! low"
    default: return ""
    }
}

func dueString(_ r: EKReminder) -> String? {
    guard let c = r.dueDateComponents, let date = Calendar.current.date(from: c) else { return nil }
    let f = DateFormatter()
    f.dateFormat = c.hour != nil ? "EEE yyyy-MM-dd HH:mm" : "EEE yyyy-MM-dd"
    return f.string(from: date)
}

func dueDate(_ r: EKReminder) -> Date? {
    r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
}

func describe(_ r: EKReminder) -> String {
    var meta: [String] = []
    if let due = dueString(r) {
        let overdue = !r.isCompleted && (dueDate(r).map { $0 < Calendar.current.startOfDay(for: Date()) || (r.dueDateComponents?.hour != nil && $0 < Date()) } ?? false)
        meta.append("due \(due)\(overdue ? " ⚠︎ overdue" : "")")
    }
    let p = priorityLabel(r.priority)
    if !p.isEmpty { meta.append(p) }
    meta.append("list: \(r.calendar.title)")
    var lines = ["• [\(r.isCompleted ? "x" : " ")] \(r.title ?? "(untitled)")", "  \(meta.joined(separator: " · "))"]
    if let n = r.notes, !n.isEmpty { lines.append("  notes: \(n.count > 200 ? String(n.prefix(200)) + "…" : n)") }
    if let u = r.url { lines.append("  url: \(u.absoluteString)") }
    lines.append("  id: \(r.calendarItemIdentifier)")
    return lines.joined(separator: "\n")
}

func setDue(_ r: EKReminder, _ value: String) throws {
    for alarm in r.alarms ?? [] { r.removeAlarm(alarm) }
    let (c, hasTime) = try parseDue(value)
    r.dueDateComponents = c
    if hasTime, let date = Calendar.current.date(from: c) {
        r.addAlarm(EKAlarm(absoluteDate: date))  // notify at the due time, like the Reminders app
    }
}

// MARK: - Tools

func listLists(_ a: [String: Any]) throws -> String {
    try ensureAccess()
    let open = fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
    let defaultId = store.defaultCalendarForNewReminders()?.calendarIdentifier
    return "\(lists().count) reminder list(s):\n\n" + lists().map { l in
        let n = open.filter { $0.calendar.calendarIdentifier == l.calendarIdentifier }.count
        return "• \(l.title)\(l.calendarIdentifier == defaultId ? " (default)" : "") — \(n) open · \(l.source.title)\n  id: \(l.calendarIdentifier)"
    }.joined(separator: "\n")
}

func listReminders(_ a: [String: Any]) throws -> String {
    try ensureAccess()
    let cals = a.str("list").isEmpty ? nil : [try findList(a.str("list"))]
    let includeCompleted = a.bool("includeCompleted", false)
    var dueEnd: Date?
    if !a.str("dueBefore").isEmpty {
        let (c, _) = try parseDue(a.str("dueBefore"))
        dueEnd = Calendar.current.date(from: c).flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) }
    }
    var items = fetch(includeCompleted
        ? store.predicateForReminders(in: cals)
        : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueEnd, calendars: cals))
    if let dueEnd { items = items.filter { dueDate($0).map { $0 < dueEnd } ?? false } }
    let query = a.str("query").lowercased()
    if !query.isEmpty {
        items = items.filter { (($0.title ?? "") + " " + ($0.notes ?? "")).lowercased().contains(query) }
    }
    // Due ones first (soonest first), then undated, newest created first.
    items.sort { x, y in
        switch (dueDate(x), dueDate(y)) {
        case let (dx?, dy?): return dx < dy
        case (.some, nil): return true
        case (nil, .some): return false
        default: return (x.creationDate ?? .distantPast) > (y.creationDate ?? .distantPast)
        }
    }
    let limit = max(1, a.int("limit", 50))
    if items.isEmpty { return "No reminders found." }
    return "\(items.count) reminder(s)\(items.count > limit ? " (showing \(limit))" : ""):\n\n"
        + items.prefix(limit).map(describe).joined(separator: "\n\n")
}

func createReminder(_ a: [String: Any]) throws -> String {
    try ensureAccess()
    let r = EKReminder(eventStore: store)
    r.title = try a.require("title")
    if a.str("list").isEmpty {
        guard let def = store.defaultCalendarForNewReminders() else { throw ToolError("No default reminder list; pass 'list'") }
        r.calendar = def
    } else {
        r.calendar = try findList(a.str("list"))
    }
    if !a.str("due").isEmpty { try setDue(r, a.str("due")) }
    if !a.str("notes").isEmpty { r.notes = a.str("notes") }
    if let p = parsePriority(a.str("priority")) { r.priority = p }
    if let u = URL(string: a.str("url")), !a.str("url").isEmpty { r.url = u }
    try store.save(r, commit: true)
    return "Created reminder:\n" + describe(r)
}

func updateReminder(_ a: [String: Any]) throws -> String {
    try ensureAccess()
    let r = try reminder(try a.require("id"))
    if a.has("title") { r.title = a.str("title") }
    if a.bool("clearDue", false) {
        r.dueDateComponents = nil
        for alarm in r.alarms ?? [] { r.removeAlarm(alarm) }
    } else if !a.str("due").isEmpty {
        try setDue(r, a.str("due"))
    }
    if a.has("notes") { r.notes = a.str("notes") }
    if a.has("priority"), let p = parsePriority(a.str("priority")) { r.priority = p }
    if !a.str("list").isEmpty { r.calendar = try findList(a.str("list")) }
    if let done = a.optBool("completed") { r.isCompleted = done }
    try store.save(r, commit: true)
    return "Updated reminder:\n" + describe(r)
}

func completeReminders(_ a: [String: Any]) throws -> String {
    try ensureAccess()
    var ids = a.list("ids")
    if !a.str("id").isEmpty { ids.insert(a.str("id"), at: 0) }
    guard !ids.isEmpty else { throw ToolError("Pass 'id' or 'ids'") }
    let done = a.bool("completed", true)
    var titles: [String] = []
    for id in ids {
        let r = try reminder(id)
        r.isCompleted = done
        try store.save(r, commit: false)
        titles.append(r.title ?? id)
    }
    try store.commit()
    return "Marked \(titles.count) reminder(s) as \(done ? "completed" : "not completed"): " + titles.joined(separator: ", ")
}

func deleteReminder(_ a: [String: Any]) throws -> String {
    try ensureAccess()
    let r = try reminder(try a.require("id"))
    let title = r.title ?? "(untitled)"
    try store.remove(r, commit: true)
    return "Deleted reminder “\(title)”."
}

let dueHelp = "YYYY-MM-DD (all day) or YYYY-MM-DD HH:MM (with a notification at that time)"

runServer(name: serverName, version: "1.0.0", tools: [
    Tool(name: "reminders_list_lists", description: "List reminder lists with open counts.",
         properties: [:], required: [], handler: listLists),
    Tool(name: "reminders_list", description: "List reminders (open by default), soonest due first. Filter by list, due date or text.",
         properties: ["list": prop("string", "List name or id (optional; all lists if empty)"),
                      "query": prop("string", "Text in title or notes"),
                      "dueBefore": prop("string", "Only reminders due on/before YYYY-MM-DD (e.g. today for 'what's due today')"),
                      "includeCompleted": prop("boolean", "Include completed reminders (default false)"),
                      "limit": prop("integer", "Max results (default 50)")],
         required: [], handler: listReminders),
    Tool(name: "reminders_create", description: "Create a reminder.",
         properties: ["title": prop("string", "Title"),
                      "list": prop("string", "List name or id (default list if empty)"),
                      "due": prop("string", dueHelp),
                      "notes": prop("string", "Notes"),
                      "priority": prop("string", "high, medium, low or none"),
                      "url": prop("string", "Link to attach (e.g. a message: or https: URL)")],
         required: ["title"], handler: createReminder),
    Tool(name: "reminders_update", description: "Change a reminder's title, due date, notes, priority, list or completion.",
         properties: ["id": prop("string", "Reminder id"),
                      "title": prop("string", "New title"),
                      "due": prop("string", dueHelp),
                      "clearDue": prop("boolean", "Remove the due date"),
                      "notes": prop("string", "New notes"),
                      "priority": prop("string", "high, medium, low or none"),
                      "list": prop("string", "Move to this list"),
                      "completed": prop("boolean", "Mark completed / not completed")],
         required: ["id"], handler: updateReminder),
    Tool(name: "reminders_complete", description: "Mark one or more reminders completed (or not, with completed=false).",
         properties: ["id": prop("string", "Reminder id"), "ids": arrayProp("string", "Several reminder ids"),
                      "completed": prop("boolean", "Default true")],
         required: [], handler: completeReminders),
    Tool(name: "reminders_delete", description: "Delete a reminder permanently.",
         properties: ["id": prop("string", "Reminder id")], required: ["id"], handler: deleteReminder),
])
