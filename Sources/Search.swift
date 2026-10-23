// Search you can predict: it walks the folder you're in (and everything below it) and matches names.
// "Name & contents" adds Spotlight's text index, scoped to the same folder.

import AppKit
import UniformTypeIdentifiers

struct SearchQuery: Equatable {
    /// Something to look for: words or a filter.
    var isActive: Bool { !text.isEmpty || kind != "any" || date != "any" || size != "any" }

    var text = ""
    var contents = false
    var kind = "any"     // any, folders, images, video, audio, documents, archives, code
    var date = "any"     // any, today, week, month, year
    var size = "any"     // any, small (< 1 MB), medium (1–100 MB), large (> 100 MB)

    static let kinds = [("any", "Any kind"), ("folders", "Folders"), ("images", "Pictures"), ("video", "Videos"),
                        ("audio", "Music & audio"), ("documents", "Documents"), ("archives", "Archives"), ("code", "Code")]
    static let dates = [("any", "Any date"), ("today", "Today"), ("week", "This week"), ("month", "This month"), ("year", "This year")]
    static let sizes = [("any", "Any size"), ("small", "Under 1 MB"), ("medium", "1 – 100 MB"), ("large", "Over 100 MB")]

    /// Plain text matches anywhere in the name; * and ? work as in Explorer (*.pdf, report-??.txt).
    func nameMatches(_ name: String) -> Bool {
        if text.isEmpty { return true }   // filters only, e.g. "every video in here"
        if text.contains("*") || text.contains("?") {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: text)
                .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func passesFilters(_ item: FileItem) -> Bool {
        if kind != "any" {
            if kind == "folders" { if !item.isFolder { return false } }
            else {
                guard !item.isFolder, let id = item.typeID, let type = UTType(id) else { return false }
                let ok: Bool
                switch kind {
                case "images": ok = type.conforms(to: .image)
                case "video": ok = type.conforms(to: .movie) || type.conforms(to: .video)
                case "audio": ok = type.conforms(to: .audio)
                case "archives": ok = type.conforms(to: .archive)
                case "code": ok = type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
                default: ok = type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
                    || type.conforms(to: .spreadsheet) || id.contains("word") || id.contains("opendocument") || id.contains("rtf")
                }
                if !ok { return false }
            }
        }
        if date != "any" {
            guard let m = item.modified else { return false }
            let cal = Calendar.current
            let unit: Calendar.Component = ["today": .day, "week": .weekOfYear, "month": .month][date] ?? .year
            if !cal.isDate(m, equalTo: Date(), toGranularity: unit) { return false }
        }
        if size != "any" {
            guard let s = item.size else { return false }
            switch size {
            case "small": if s >= 1_000_000 { return false }
            case "medium": if s < 1_000_000 || s > 100_000_000 { return false }
            default: if s <= 100_000_000 { return false }
            }
        }
        return true
    }
}

/// One running search. Results arrive in batches so the first hits show immediately.
@MainActor
final class SearchRun {
    private var cancelled = false
    private var spotlight: NSMetadataQuery?
    private var observers: [Any] = []
    static let limit = 20_000

    func cancel() {
        cancelled = true
        spotlight?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    init(root: URL, query: SearchQuery, showHidden: Bool,
         batch: @escaping @MainActor ([FileItem]) -> Void, done: @escaping @MainActor (Bool) -> Void) {
        if query.contents { runSpotlight(root, query, batch, done) } else { walk(root, query, showHidden, batch, done) }
    }

    private func walk(_ root: URL, _ query: SearchQuery, _ showHidden: Bool,
                      _ batch: @escaping @MainActor ([FileItem]) -> Void, _ done: @escaping @MainActor (Bool) -> Void) {
        let isCancelled: @Sendable () -> Bool = { [weak self] in
            DispatchQueue.main.sync { MainActor.assumeIsolated { self?.cancelled ?? true } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHidden { options.insert(.skipsHiddenFiles) }
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: FileItem.keys, options: options, errorHandler: { _, _ in true })
            var pending: [FileItem] = []
            var found = 0
            var lastFlush = Date()
            var checked = 0
            func flush() {
                let chunk = pending
                pending = []
                DispatchQueue.main.async { MainActor.assumeIsolated { batch(chunk) } }
            }
            while let url = walker?.nextObject() as? URL {
                checked += 1
                if checked % 2000 == 0, isCancelled() { return }
                guard query.nameMatches(url.lastPathComponent) else { continue }
                let item = FileItem(url: url)
                guard query.passesFilters(item) else { continue }
                pending.append(item)
                found += 1
                if pending.count >= 200 || Date().timeIntervalSince(lastFlush) > 0.15 {
                    if isCancelled() { return }
                    flush()
                    lastFlush = Date()
                }
                if found >= SearchRun.limit { break }
            }
            if isCancelled() { return }
            flush()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(found >= SearchRun.limit) } }
        }
    }

    private func runSpotlight(_ root: URL, _ query: SearchQuery,
                              _ batch: @escaping @MainActor ([FileItem]) -> Void, _ done: @escaping @MainActor (Bool) -> Void) {
        let q = NSMetadataQuery()
        let text = query.text.replacingOccurrences(of: "\"", with: "")
        q.predicate = NSPredicate(format: "(kMDItemFSName LIKE[cd] %@) OR (kMDItemTextContent LIKE[cd] %@)", "*\(text)*", "*\(text)*")
        q.searchScopes = [root]
        let finished = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                q.disableUpdates()
                let urls = (0..<q.resultCount).compactMap { (q.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemURLKey) as? URL }
                let items = urls.prefix(SearchRun.limit).map(FileItem.init).filter(query.passesFilters)
                batch(items)
                done(urls.count >= SearchRun.limit)
                q.stop()
            }
        }
        observers.append(finished)
        spotlight = q
        q.start()
    }
}
