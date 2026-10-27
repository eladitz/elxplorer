// The once-a-month "enjoying it?" prompt and the Ko-fi link. The same file lives in Elconvo and Elxplorer.
//
// Asks only after a few uses (conversions in Elconvo, days of use in Elxplorer). "Yes" leads to a donation
// offer; donating (or saying you already have) pauses the question for a year in both apps, anything else
// for a month.

import AppKit

@MainActor
enum Donation {
    static let page = URL(string: "https://ko-fi.com/eladitzkin")!

    private static let defaults = UserDefaults.standard
    /// Shared by every itzkin app, so a donation through one quiets the others.
    private static let shared = UserDefaults(suiteName: "com.itzkin.apps") ?? .standard
    private static let nextAskKey = "nextDonationAsk"
    private static let usesKey = "successfulConversions"
    private static let donatedUntilKey = "donatedUntil"
    private static let lastDayKey = "lastUseDay"
    private static let month: TimeInterval = 30 * 24 * 3600
    private static let year: TimeInterval = 365 * 24 * 3600

    private static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "it" }

    /// What the first prompt says about how much it's been used.
    static var usageLine: (Int) -> String = { "You've converted \($0) files with it so far." }

    /// The Mac App Store only allows tips through In-App Purchase, so its builds have no Ko-fi prompt or link.
    static var enabled: Bool { !Distribution.appStore }

    static func start() {
        guard enabled else { return }
        if defaults.object(forKey: nextAskKey) == nil { snooze(month) }
        // These apps run for weeks without relaunching, so look again a few times a day.
        let timer = Timer(timeInterval: 4 * 3600, repeats: true) { _ in MainActor.assumeIsolated { askIfDue() } }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { askIfDue() }
    }

    static func recordUse() {
        defaults.set(defaults.integer(forKey: usesKey) + 1, forKey: usesKey)
    }

    /// Counts at most once per calendar day (for apps where "a use" is a day of using it).
    static func recordDay() {
        let today = Calendar.current.startOfDay(for: Date())
        guard (defaults.object(forKey: lastDayKey) as? Date) != today else { return }
        defaults.set(today, forKey: lastDayKey)
        recordUse()
    }

    static func askIfDue() {
        guard let next = defaults.object(forKey: nextAskKey) as? Date, Date() >= next,
              defaults.integer(forKey: usesKey) >= 3,
              NSEvent.pressedMouseButtons == 0   // never in the middle of a drag
        else { return }
        if let until = shared.object(forKey: donatedUntilKey) as? Date, Date() < until {
            defaults.set(until, forKey: nextAskKey)
            return
        }
        ask()
    }

    static func ask() {
        NSApp.activate(ignoringOtherApps: true)

        let like = NSAlert()
        like.messageText = "Enjoying \(appName)?"
        like.informativeText = usageLine(defaults.integer(forKey: usesKey))
        like.addButton(withTitle: "Yes, I like it")
        like.addButton(withTitle: "Not really")
        guard like.runModal() == .alertFirstButtonReturn else { snooze(month); return }

        let give = NSAlert()
        give.messageText = "Glad to hear it!"
        give.informativeText = "\(appName) is free and made by one person. If it saves you time, a small donation on Ko-fi helps keep it going."
        give.addButton(withTitle: "Donate on Ko-fi")
        give.addButton(withTitle: "Maybe Later")
        give.addButton(withTitle: "I've Already Donated")
        switch give.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(page)
            donated()
        case .alertThirdButtonReturn:
            donated()
        default:
            snooze(month)
        }
    }

    private static func donated() {
        let until = Date().addingTimeInterval(year)
        shared.set(until, forKey: donatedUntilKey)
        defaults.set(until, forKey: nextAskKey)
    }

    private static func snooze(_ interval: TimeInterval) {
        defaults.set(Date().addingTimeInterval(interval), forKey: nextAskKey)
    }
}
