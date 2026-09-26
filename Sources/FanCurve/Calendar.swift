import AppKit
import Carbon.HIToolbox
import EventKit
import SwiftUI
import UserNotifications

/// A calendar event reduced to what the app shows.
struct Meeting: Identifiable, Equatable {
    let id: String
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendar: String
    let color: Color
    let link: MeetingLink?

    func isOngoing(at now: Date = Date()) -> Bool { start <= now && now < end }
    var timeRange: String {
        isAllDay ? "All day" : "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// A video-call link found in an event, with the app-specific URL to open it directly.
struct MeetingLink: Equatable {
    let service: String
    let url: URL

    private static let patterns: [(String, String)] = [
        ("Zoom", #"https?://[\w.-]*zoom\.(us|com)/(j|my|w|s)/[^\s"'<>)]+"#),
        ("Google Meet", #"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s"'<>)]*"#),
        ("Teams", #"https?://teams\.(microsoft|live)\.com/(l/meetup-join|meet)/[^\s"'<>)]+"#),
        ("Webex", #"https?://[\w.-]+\.webex\.com/[^\s"'<>)]+"#),
        ("FaceTime", #"https?://facetime\.apple\.com/join[^\s"'<>)]+"#),
        ("Whereby", #"https?://whereby\.com/[^\s"'<>)]+"#),
        ("Slack", #"https?://app\.slack\.com/huddle/[^\s"'<>)]+"#),
        ("Jitsi", #"https?://meet\.jit\.si/[^\s"'<>)]+"#),
    ]

    static func find(in event: EKEvent) -> MeetingLink? {
        let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for text in texts {
            for (service, pattern) in patterns {
                if let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                   let url = URL(string: String(text[r])) {
                    return MeetingLink(service: service, url: url)
                }
            }
        }
        return nil
    }

    /// Opens Zoom and Teams links in their apps instead of a browser tab when installed.
    func open() {
        var target = url
        let s = url.absoluteString
        if service == "Zoom", appInstalled("zoommtg://"),
           let id = s.range(of: #"/j/(\d+)"#, options: .regularExpression).map({ String(s[$0].dropFirst(3)) }) {
            let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pwd" }?.value
            target = URL(string: "zoommtg://zoom.us/join?action=join&confno=\(id)" + (pwd.map { "&pwd=\($0)" } ?? "")) ?? url
        } else if service == "Teams", appInstalled("msteams://") {
            target = URL(string: s.replacingOccurrences(of: "https://", with: "msteams://")) ?? url
        }
        NSWorkspace.shared.open(target)
    }

    private func appInstalled(_ scheme: String) -> Bool {
        URL(string: scheme).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
    }
}

@MainActor
final class CalendarStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum MenuBarMode: String, CaseIterable, Identifiable {
        case soon, always, never
        var id: String { rawValue }
        var label: String {
            switch self {
            case .soon: return "Within 30 minutes of a meeting"
            case .always: return "Whenever there's a meeting today"
            case .never: return "Never"
            }
        }
    }

    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var meetings: [Meeting] = []          // today + tomorrow
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var now = Date()

    @Published var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: "calMenuBar") } }
    @Published var hiddenCalendars: Set<String> { didSet { defaults.set(Array(hiddenCalendars), forKey: "calHidden"); reload() } }
    @Published var hideAllDay: Bool { didSet { defaults.set(hideAllDay, forKey: "calHideAllDay"); reload() } }
    @Published var hideDeclined: Bool { didSet { defaults.set(hideDeclined, forKey: "calHideDeclined"); reload() } }
    @Published var notify: Bool { didSet { defaults.set(notify, forKey: "calNotify"); if notify { requestNotifications() }; scheduleNotifications() } }
    @Published var leadMinutes: Int { didSet { defaults.set(leadMinutes, forKey: "calLead"); scheduleNotifications() } }
    /// Mute the microphone automatically when joining from FanCurve.
    @Published var muteOnJoin: Bool { didSet { defaults.set(muteOnJoin, forKey: "calMuteOnJoin") } }

    var onJoin: (() -> Void)?

    private let store = EKEventStore()
    /// UserNotifications needs a real app bundle; debug executables run without one.
    private let canNotify = Bundle.main.bundleIdentifier != nil
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    override init() {
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "calMenuBar") ?? "") ?? .soon
        hiddenCalendars = Set(defaults.stringArray(forKey: "calHidden") ?? [])
        hideAllDay = defaults.object(forKey: "calHideAllDay") as? Bool ?? false
        hideDeclined = defaults.object(forKey: "calHideDeclined") as? Bool ?? true
        notify = defaults.object(forKey: "calNotify") as? Bool ?? true
        leadMinutes = defaults.object(forKey: "calLead") as? Int ?? 1
        muteOnJoin = defaults.bool(forKey: "calMuteOnJoin")
        super.init()

        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Minute tick keeps "in 12 min" labels fresh; a full reload every 5 minutes catches edge cases.
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                ticks += 1
                if ticks % 10 == 0 { self.reload() }
            }
        }
        timer?.tolerance = 5

        if canNotify {
            UNUserNotificationCenter.current().delegate = self
            registerNotificationCategory()
        }
        reload()
    }

    // MARK: access

    var hasAccess: Bool { access == .fullAccess }

    /// Asks for calendar access. Only possible from the bundled app (needs the Info.plist usage text).
    func requestAccess() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else { return }
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.access = EKEventStore.authorizationStatus(for: .event)
                self.store.reset()
                self.reload()
            }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    // MARK: events

    func reload() {
        access = EKEventStore.authorizationStatus(for: .event)
        now = Date()
        guard hasAccess else { meetings = []; calendars = []; return }
        calendars = store.calendars(for: .event).sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
        let visible = calendars.filter { !hiddenCalendars.contains($0.calendarIdentifier) }
        guard !visible.isEmpty else { meetings = []; scheduleNotifications(); return }

        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 2, to: start)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: visible))
        meetings = events.compactMap { e -> Meeting? in
            if hideAllDay && e.isAllDay { return nil }
            if hideDeclined, e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined { return nil }
            if e.status == .canceled { return nil }
            return Meeting(id: "\(e.calendarItemIdentifier)-\(e.startDate.timeIntervalSince1970)",
                           eventID: e.eventIdentifier ?? e.calendarItemIdentifier,
                           title: e.title?.isEmpty == false ? e.title! : "Untitled",
                           start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                           calendar: e.calendar.title, color: Color(nsColor: e.calendar.color),
                           link: MeetingLink.find(in: e))
        }
        .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
        scheduleNotifications()
    }

    func isToday(_ m: Meeting) -> Bool { Calendar.current.isDate(m.start, inSameDayAs: now) }

    /// Remaining timed meetings today (ongoing first).
    var upcomingToday: [Meeting] { meetings.filter { !$0.isAllDay && isToday($0) && $0.end > now } }

    /// The meeting to show in the menu bar: ongoing, or the next one today.
    var next: Meeting? { upcomingToday.first }

    /// What "Join Next Meeting" joins: a call in progress (or starting within 10 min), else the next with a link.
    var joinable: Meeting? {
        let withLink = meetings.filter { !$0.isAllDay && $0.link != nil && $0.end > now }
        return withLink.first { $0.start.timeIntervalSince(now) < 10 * 60 } ?? withLink.first
    }

    func join(_ m: Meeting? = nil) {
        guard let m = m ?? joinable else { NSSound.beep(); return }
        if let link = m.link {
            link.open()
            if muteOnJoin { onJoin?() }
        } else {
            openInCalendar(m)
        }
    }

    func openInCalendar(_ m: Meeting) {
        let enc = m.eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m.eventID
        if let url = URL(string: "ical://ekevent/\(enc)?method=show&options=more") { NSWorkspace.shared.open(url) }
    }

    // MARK: menu bar entry

    /// Binding for the MenuBarExtra's isInserted. The setter ignores SwiftUI's write-backs
    /// (see MicMuter.showIndicator: republishing here would loop forever).
    var showInMenuBar: Bool {
        get {
            guard hasAccess, let m = next else { return false }
            switch menuBarMode {
            case .always: return true
            case .soon: return m.isOngoing(at: now) || m.start.timeIntervalSince(now) <= 30 * 60
            case .never: return false
            }
        }
        set { if !newValue && menuBarMode == .always && next != nil { menuBarMode = .never } }
    }

    var menuBarTitle: String {
        guard let m = next else { return "" }
        let title = m.title.count > 22 ? String(m.title.prefix(21)) + "…" : m.title
        return "\(title) · \(relative(m))"
    }

    func relative(_ m: Meeting) -> String {
        if m.isOngoing(at: now) {
            let left = Int(m.end.timeIntervalSince(now) / 60)
            return left <= 0 ? "ending" : "now"
        }
        let mins = Int(ceil(m.start.timeIntervalSince(now) / 60))
        if mins < 60 { return "in \(max(mins, 1)) min" }
        return m.start.formatted(date: .omitted, time: .shortened)
    }

    // MARK: notifications

    private func requestNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func registerNotificationCategory() {
        let join = UNNotificationAction(identifier: "JOIN", title: "Join", options: [.foreground])
        let cat = UNNotificationCategory(identifier: "MEETING", actions: [join], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    private func scheduleNotifications() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard notify, hasAccess else { return }
        for m in meetings where !m.isAllDay {
            let fire = m.start.addingTimeInterval(TimeInterval(-leadMinutes * 60))
            guard fire > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = m.title
            content.body = leadMinutes == 0 ? "Starting now" + (m.link.map { " · \($0.service)" } ?? "")
                                            : "In \(leadMinutes) min · \(m.timeRange)" + (m.link.map { " · \($0.service)" } ?? "")
            content.sound = .default
            content.categoryIdentifier = m.link != nil ? "MEETING" : ""
            content.userInfo = ["meeting": m.id]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
            center.add(UNNotificationRequest(identifier: m.id, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["meeting"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let m = self.meetings.first(where: { $0.id == id }) {
                    if action == "JOIN" || action == UNNotificationDefaultActionIdentifier, m.link != nil { self.join(m) }
                    else { self.openInCalendar(m) }
                }
            }
            completion()
        }
    }
}

// MARK: - Schedule panel source

@MainActor
final class ScheduleSource: PanelSource {
    let calendar: CalendarStore
    init(calendar: CalendarStore) { self.calendar = calendar }

    var placeholder: String { "Search today's and tomorrow's schedule…" }

    func items(for query: String) -> [PanelItem] {
        guard calendar.hasAccess else {
            return [PanelItem(id: "access", title: "Allow Calendar Access", subtitle: "FanCurve needs access to show your schedule",
                              symbol: "calendar.badge.exclamationmark", tint: .red) { [calendar] in calendar.requestAccess(); return true }]
        }
        let items = calendar.meetings.map { m -> PanelItem in
            let today = calendar.isToday(m)
            let past = m.end <= calendar.now
            return PanelItem(id: m.id, section: today ? "Today" : "Tomorrow", title: m.title,
                             subtitle: "\(m.timeRange) · \(m.calendar)" + (m.link.map { " · \($0.service)" } ?? ""),
                             accessory: past ? "Ended" : m.link != nil ? (m.isOngoing(at: calendar.now) ? "Join now" : calendar.relative(m)) : nil,
                             symbol: m.link != nil ? "video.fill" : m.isAllDay ? "sun.max.fill" : "calendar",
                             tint: m.color, keywords: [m.calendar, m.link?.service ?? ""]) { [calendar] in
                calendar.join(m); return true
            }
        }
        if items.isEmpty {
            return [PanelItem(id: "empty", title: "No meetings today or tomorrow", symbol: "checkmark.circle.fill", tint: .green) { true }]
        }
        return items.filtered(query)
    }
}

// MARK: - Quick add & availability

/// An event parsed from a sentence like "lunch with Sam tomorrow at 1pm for 45 min".
struct EventDraft: Equatable {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
}

enum EventParser {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    /// Words that introduce the command rather than belong to the title.
    static let prefixes = ["create event ", "new event ", "add event ", "event ", "add "]

    /// Returns nil when the text has no date or time in it.
    static func parse(_ text: String, now: Date = Date()) -> EventDraft? {
        var s = text.trimmingCharacters(in: .whitespaces)
        for p in prefixes where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        let ns = s as NSString
        guard let m = detector?.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), var start = m.date else { return nil }
        let matched = ns.substring(with: m.range).lowercased()
        var title = ns.replacingCharacters(in: m.range, with: " ")

        // "for 45 min", "for 1.5 hours", "for 2h"
        var duration = m.duration > 0 ? m.duration : 3600
        let durRe = try! NSRegularExpression(pattern: #"\bfor\s+(\d+(?:[.,]\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes)\b"#, options: .caseInsensitive)
        if let d = durRe.firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)) {
            let n = Double((title as NSString).substring(with: d.range(at: 1)).replacingOccurrences(of: ",", with: ".")) ?? 1
            duration = (title as NSString).substring(with: d.range(at: 2)).lowercased().hasPrefix("h") ? n * 3600 : n * 60
            title = (title as NSString).replacingCharacters(in: d.range, with: " ")
        }

        // A date without a time ("3 october", "friday") is an all-day event.
        let timed = matched.range(of: #"\d{1,2}(:\d{2})?\s*(am|pm)|\d{1,2}[:.]\d{2}|\bnoon\b|\bmidnight\b|\d{1,2}\s*-\s*\d"#,
                                  options: .regularExpression) != nil
        let cal = Calendar.current
        var end: Date
        if timed {
            end = start.addingTimeInterval(duration)
        } else {
            start = cal.startOfDay(for: start)
            let last = cal.startOfDay(for: start.addingTimeInterval(max(m.duration, 0)))
            end = cal.date(byAdding: .day, value: 1, to: last)!
        }
        // Tidy leftover joining words: "lunch with Sam  at " → "lunch with Sam".
        let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        var trimmed = words
        let joiners: Set<String> = ["at", "on", "from", "to", "by", "in", "for", "-", "–"]
        while let l = trimmed.last, joiners.contains(l.lowercased()) { trimmed.removeLast() }
        while let f = trimmed.first, joiners.contains(f.lowercased()) { trimmed.removeFirst() }
        var t = trimmed.joined(separator: " ")
        if t.isEmpty { t = "New Event" }
        t = t.prefix(1).uppercased() + t.dropFirst()
        if end <= start { end = start.addingTimeInterval(3600) }
        return EventDraft(title: t, start: start, end: end, allDay: !timed)
    }

    static func describe(_ d: EventDraft) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        if d.allDay {
            f.timeStyle = .none
            let days = Calendar.current.dateComponents([.day], from: d.start, to: d.end).day ?? 1
            return f.string(from: d.start) + (days > 1 ? " · \(days) days" : " · all day")
        }
        f.timeStyle = .short
        let t = DateFormatter(); t.timeStyle = .short; t.dateStyle = .none
        let mins = Int(d.end.timeIntervalSince(d.start) / 60)
        return "\(f.string(from: d.start))–\(t.string(from: d.end)) · " + (mins % 60 == 0 ? "\(mins / 60) h" : "\(mins) min")
    }

    /// Free periods of at least `minMinutes` between `startHour` and `endHour` on `day`, avoiding `busy`.
    static func freeSlots(busy: [(start: Date, end: Date)], day: Date, startHour: Int, endHour: Int, now: Date,
                          minMinutes: Int = 30) -> [(start: Date, end: Date)] {
        let cal = Calendar.current
        guard var cursor = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: day),
              let close = cal.date(bySettingHour: endHour, minute: 0, second: 0, of: day) else { return [] }
        if now > cursor {   // today: start from the next half hour
            let comps = cal.dateComponents([.hour, .minute], from: now)
            let rounded = cal.date(bySettingHour: comps.hour!, minute: 0, second: 0, of: now)!
                .addingTimeInterval(comps.minute! == 0 ? 0 : comps.minute! <= 30 ? 1800 : 3600)
            cursor = max(cursor, rounded)
        }
        var out: [(Date, Date)] = []
        for b in busy.filter({ $0.end > cursor && $0.start < close }).sorted(by: { $0.start < $1.start }) {
            if b.start.timeIntervalSince(cursor) >= Double(minMinutes * 60) { out.append((cursor, min(b.start, close))) }
            cursor = max(cursor, b.end)
            if cursor >= close { break }
        }
        if close.timeIntervalSince(cursor) >= Double(minMinutes * 60) { out.append((cursor, close)) }
        return out
    }
}

extension CalendarStore {
    /// Adds an event to the default calendar. Returns an error message on failure.
    func create(_ d: EventDraft) -> String? {
        guard hasAccess else { requestAccess(); return "FanCurve needs calendar access" }
        guard let calendar = store.defaultCalendarForNewEvents else { return "There's no calendar to add events to" }
        let e = EKEvent(eventStore: store)
        e.title = d.title; e.startDate = d.start; e.endDate = d.end; e.isAllDay = d.allDay; e.calendar = calendar
        do { try store.save(e, span: .thisEvent); reload(); return nil } catch { return error.localizedDescription }
    }

    var defaultCalendarName: String? { hasAccess ? store.defaultCalendarForNewEvents?.title : nil }

    /// Your free time over the next few working days, as text to paste into an email or chat.
    func availabilityText(days: Int = 3) -> String {
        guard hasAccess else { return "" }
        let cal = Calendar.current, now = Date()
        let visible = calendars.filter { !hiddenCalendars.contains($0.calendarIdentifier) }
        var lines: [String] = [], day = cal.startOfDay(for: now), found = 0
        let dayF = DateFormatter(); dayF.setLocalizedDateFormatFromTemplate("EEE d MMM")
        let timeF = DateFormatter(); timeF.timeStyle = .short; timeF.dateStyle = .none
        while found < days, lines.count < 14 {
            defer { day = cal.date(byAdding: .day, value: 1, to: day)! }
            if cal.isDateInWeekend(day) { continue }
            found += 1
            let end = cal.date(byAdding: .day, value: 1, to: day)!
            let busy = visible.isEmpty ? [] : store.events(matching: store.predicateForEvents(withStart: day, end: end, calendars: visible))
                .filter { !$0.isAllDay && $0.availability != .free && $0.status != .canceled
                    && $0.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined }
                .map { (start: $0.startDate!, end: $0.endDate!) }
            let free = EventParser.freeSlots(busy: busy, day: day, startHour: workStart, endHour: workEnd, now: now)
            guard !free.isEmpty else { continue }
            lines.append("\(dayF.string(from: day)): " + free.map { "\(timeF.string(from: $0.start))–\(timeF.string(from: $0.end))" }.joined(separator: ", "))
        }
        return lines.isEmpty ? "" : "I'm free:\n" + lines.joined(separator: "\n")
    }

    var workStart: Int { UserDefaults.standard.object(forKey: "calWorkStart") as? Int ?? 9 }
    var workEnd: Int { UserDefaults.standard.object(forKey: "calWorkEnd") as? Int ?? 17 }
}
