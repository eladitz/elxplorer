// Your real home folder. Inside the App Store's sandbox, the usual ways of asking (and "~") give the app's
// private container instead, so this asks the system's user record. Outside the sandbox it's the same answer.

import Foundation

enum Home {
    static let url: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// "~/Documents" → "/Users/you/Documents".
    static func expand(_ path: String) -> String {
        path == "~" ? url.path : path.hasPrefix("~/") ? url.path + path.dropFirst() : path
    }

    /// "/Users/you/Documents" → "~/Documents".
    static func abbreviate(_ path: String) -> String {
        path == url.path ? "~" : path.hasPrefix(url.path + "/") ? "~" + path.dropFirst(url.path.count) : path
    }
}
