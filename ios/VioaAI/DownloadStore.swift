import Foundation

/// Small helper around the app's on-device downloads folder.
///
/// Files land in `Documents/Downloads`, which is visible in the Files app
/// because `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are
/// turned on in Info.plist. That is how users get an APK / IPA they downloaded
/// from the site onto their device.
enum DownloadStore {

    static var downloadsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Returns a unique, sanitized destination URL for a suggested filename.
    static func destination(for suggestedFilename: String) -> URL {
        let directory = downloadsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = sanitize(suggestedFilename)
        let nsName = safeName as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        var candidate = directory.appendingPathComponent(safeName)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = "download" }
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        value = value.components(separatedBy: forbidden).joined(separator: "-")
        if value.count > 160 { value = String(value.suffix(160)) }
        return value
    }

    static func fileSizeString(at url: URL) -> String {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let bytes = values.fileSize
        else {
            return ""
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
