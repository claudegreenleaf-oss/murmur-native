import AppKit
import EventKit
import Foundation

final class CalendarBridge {
    static let shared = CalendarBridge()

    private let store = EKEventStore()
    private var observing = false
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "murmur.helper.calendar")

    func status() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .writeOnly: return "writeOnly"
        case .fullAccess, .authorized: return "fullAccess"
        @unknown default: return "denied"
        }
    }

    func requestAccess(_ done: @escaping (String) -> Void) {
        if EKEventStore.authorizationStatus(for: .event) != .notDetermined {
            observeIfNeeded()
            return done(status())
        }
        DispatchQueue.main.async { [self] in
            NSApp.activate(ignoringOtherApps: true)
            store.requestFullAccessToEvents { [self] _, _ in
                observeIfNeeded()
                done(status())
            }
        }
    }

    private func observeIfNeeded() {
        queue.async { [self] in
            guard !observing, status() == "fullAccess" else { return }
            observing = true
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] _ in
                self?.queue.async {
                    guard let self else { return }
                    self.debounce?.cancel()
                    let w = DispatchWorkItem { IPC.shared.send("CalendarEventsChanged", [:]) }
                    self.debounce = w
                    self.queue.asyncAfter(deadline: .now() + 1, execute: w)
                }
            }
        }
    }

    func events(fromMs: Double, toMs: Double) -> JSON {
        let st = status()
        guard st == "fullAccess" else { return ["status": st, "events": [JSON]()] }
        observeIfNeeded()
        let from = Date(timeIntervalSince1970: fromMs / 1000)
        var to = Date(timeIntervalSince1970: toMs / 1000)
        if to.timeIntervalSince(from) > 60 * 86400 { to = from.addingTimeInterval(60 * 86400) }
        if to <= from { return ["status": st, "events": [JSON]()] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let evs = store.events(matching: pred).sorted { $0.startDate < $1.startDate }.prefix(2000)
        return ["status": st, "events": evs.map(map)]
    }

    // MARK: mapping

    private static let confRegex = try? NSRegularExpression(
        pattern: #"https?://(?:[\w-]+\.)*(?:zoom(?:gov)?\.(?:us|com)/[^\s"<>)\]]+|meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s"<>)\]]*|teams\.microsoft\.com/l/meetup-join/[^\s"<>)\]]+|teams\.live\.com/meet/[^\s"<>)\]]+|webex\.com/[^\s"<>)\]]+)"#,
        options: [.caseInsensitive]
    )

    private func conferenceUrls(_ texts: [String]) -> [String] {
        var out: [String] = []
        guard let re = CalendarBridge.confRegex else { return out }
        for t in texts where !t.isEmpty {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let u = ns.substring(with: m.range)
                if !out.contains(u) { out.append(u) }
            }
        }
        return out
    }

    private func hex(_ c: NSColor?) -> String {
        guard let c = c?.usingColorSpace(.sRGB) else { return "#808080" }
        func b(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }

    private func role(_ r: EKParticipantRole) -> String {
        switch r {
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "nonParticipant"
        default: return "unknown"
        }
    }

    private func response(_ s: EKParticipantStatus) -> String {
        switch s {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .pending: return "pending"
        case .delegated: return "delegated"
        default: return "unknown"
        }
    }

    private func person(_ p: EKParticipant) -> JSON {
        var email = p.url.absoluteString
        if email.lowercased().hasPrefix("mailto:") { email = String(email.dropFirst(7)) }
        return ["name": p.name ?? "", "email": email]
    }

    private func map(_ e: EKEvent) -> JSON {
        let startMs = Int((e.startDate.timeIntervalSince1970 * 1000).rounded())
        let endMs = Int((e.endDate.timeIntervalSince1970 * 1000).rounded())
        let ident = e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? ""
        let notes = e.notes ?? ""
        let location = e.location ?? ""
        let url = e.url?.absoluteString ?? ""
        let conf = conferenceUrls([url, location, notes])
        var attendees: [JSON] = []
        var selfStatus: String?
        for a in e.attendees ?? [] {
            var d = person(a)
            d["role"] = role(a.participantRole)
            d["responseStatus"] = response(a.participantStatus)
            d["isCurrentUser"] = a.isCurrentUser
            if a.isCurrentUser { selfStatus = response(a.participantStatus) }
            attendees.append(d)
        }
        let status: String
        switch e.status {
        case .confirmed: status = "confirmed"
        case .tentative: status = "tentative"
        case .canceled: status = "canceled"
        default: status = "none"
        }
        var d: JSON = [
            "externalId": "\(ident)|\(startMs)",
            "title": e.title ?? "",
            "startMs": startMs,
            "endMs": endMs,
            "isAllDay": e.isAllDay,
            "location": location,
            "notes": String(notes.prefix(2000)),
            "url": url,
            "calendarName": e.calendar?.title ?? "",
            "calendarColor": hex(e.calendar?.color),
            "status": status,
            "attendees": attendees,
            "selfIsOrganizer": e.organizer?.isCurrentUser ?? false,
            "isRecurring": e.hasRecurrenceRules,
        ]
        if conf.count > 0 { d["conferenceUrl"] = conf[0] }
        if conf.count > 1 { d["alternateConferenceUrl"] = conf[1] }
        if let o = e.organizer { d["organizer"] = person(o) }
        if let s = selfStatus { d["selfResponseStatus"] = s }
        if e.hasRecurrenceRules { d["seriesKey"] = ident }
        return d
    }
}
