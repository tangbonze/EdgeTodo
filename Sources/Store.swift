import Foundation
import EventKit
import AppKit

// MARK: - 列表项包装

struct TodoItem: Identifiable, Equatable {
    let reminder: EKReminder

    var id: String { reminder.calendarItemIdentifier }
    var title: String { reminder.title ?? L10n.t("（无标题）", "(No title)") }
    var isCompleted: Bool { reminder.isCompleted }

    var due: Date? {
        guard let c = reminder.dueDateComponents else { return nil }
        return Calendar.current.date(from: c)
    }

    static func == (lhs: TodoItem, rhs: TodoItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.due == rhs.due
            && lhs.isCompleted == rhs.isCompleted
    }
}

// MARK: - 数据层：直接读写系统「提醒事项」

final class TodoStore {
    static let shared = TodoStore()

    let ek = EKEventStore()

    private(set) var lists: [EKCalendar] = []
    private(set) var items: [TodoItem] = []
    private(set) var authGranted: Bool = false
    private(set) var authDenied: Bool = false
    private(set) var lastError: String?

    /// 任何数据变化都会回调（主线程）
    var onChange: (() -> Void)?

    var selectedListID: String? {
        get { UserDefaults.standard.string(forKey: "selectedListID") }
        set {
            UserDefaults.standard.set(newValue, forKey: "selectedListID")
            reload()
        }
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: ek, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        applyAuth(status)
        if status == .notDetermined {
            requestAccess()
        } else if authGranted {
            reload()
        }
    }

    // MARK: 权限

    private func applyAuth(_ status: EKAuthorizationStatus) {
        if #available(macOS 14.0, *) {
            authGranted = (status == .fullAccess)
        } else {
            authGranted = (status == .authorized)
        }
        authDenied = (status == .denied || status == .restricted)
    }

    func requestAccess() {
        let done: (Bool, Error?) -> Void = { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.applyAuth(EKEventStore.authorizationStatus(for: .reminder))
                if granted {
                    self.lastError = nil
                    self.reload()
                } else if let error = error {
                    self.lastError = error.localizedDescription
                    self.notify()
                } else {
                    self.notify()
                }
            }
        }
        if #available(macOS 14.0, *) {
            ek.requestFullAccessToReminders(completion: done)
        } else {
            ek.requestAccess(to: .reminder, completion: done)
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }

    func openRemindersApp() {
        let url = URL(fileURLWithPath: "/System/Applications/Reminders.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: 读取

    var selectedList: EKCalendar? {
        if let id = selectedListID, let cal = ek.calendar(withIdentifier: id) {
            return cal
        }
        return ek.defaultCalendarForNewReminders() ?? lists.first
    }

    func reload() {
        applyAuth(EKEventStore.authorizationStatus(for: .reminder))
        guard authGranted else {
            lists = []
            items = []
            notify()
            return
        }
        lists = ek.calendars(for: .reminder)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        guard let cal = selectedList else {
            items = []
            notify()
            return
        }
        let predicate = ek.predicateForReminders(in: [cal])
        ek.fetchReminders(matching: predicate) { [weak self] found in
            DispatchQueue.main.async { self?.apply(found ?? []) }
        }
    }

    private func apply(_ raw: [EKReminder]) {
        let active = raw.filter { !$0.isCompleted }
        let sorted = active.sorted { a, b in
            let da = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let db = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            switch (da, db) {
            case let (x?, y?):
                if x != y { return x < y }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            let ca = a.creationDate ?? Date.distantPast
            let cb = b.creationDate ?? Date.distantPast
            return ca > cb
        }
        items = sorted.map { TodoItem(reminder: $0) }
        notify()
    }

    private func notify() {
        onChange?()
    }

    // MARK: 写入

    @discardableResult
    func add(title: String, due: Date?) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let cal = selectedList else {
            lastError = L10n.t(
                "没有可用的列表，请先在「提醒事项」中建一个",
                "No lists available — create one in Reminders first"
            )
            notify()
            return false
        }
        let r = EKReminder(eventStore: ek)
        r.title = trimmed
        r.calendar = cal
        if let due = due { Self.applyDue(r, due) }
        do {
            try ek.save(r, commit: true)
            lastError = nil
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            notify()
            return false
        }
    }

    static func applyDue(_ reminder: EKReminder, _ date: Date) {
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        comps.timeZone = TimeZone.current
        reminder.dueDateComponents = comps
        reminder.alarms = [EKAlarm(absoluteDate: date)]
    }

    func complete(_ item: TodoItem) {
        item.reminder.isCompleted = true
        item.reminder.completionDate = Date()
        do {
            try ek.save(item.reminder, commit: true)
            items.removeAll { $0.id == item.id }
            notify()
            reload()
        } catch {
            lastError = error.localizedDescription
            notify()
        }
    }

    func setDue(_ item: TodoItem, _ date: Date?) {
        if let date = date {
            Self.applyDue(item.reminder, date)
        } else {
            item.reminder.alarms = []
            item.reminder.dueDateComponents = nil
        }
        persist(item)
    }

    func move(_ item: TodoItem, to calendar: EKCalendar) {
        item.reminder.calendar = calendar
        persist(item)
    }

    func delete(_ item: TodoItem) {
        do {
            try ek.remove(item.reminder, commit: true)
            items.removeAll { $0.id == item.id }
            notify()
            reload()
        } catch {
            lastError = error.localizedDescription
            notify()
        }
    }

    private func persist(_ item: TodoItem) {
        do {
            try ek.save(item.reminder, commit: true)
            reload()
        } catch {
            lastError = error.localizedDescription
            notify()
        }
    }
}
