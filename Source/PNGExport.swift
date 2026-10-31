import AppKit

enum PNGExport {
    static func save(_ bitmap: NSBitmapImageRep, to directory: URL, date: Date = Date()) throws -> URL {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "QuickMark", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法生成 PNG 图像。"])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let name = "QuickMark_\(formatter.string(from: date))"
        for index in 0..<1000 {
            let suffix = index == 0 ? "" : "_\(index + 1)"
            let url = directory.appendingPathComponent(name + suffix + ".png")
            do {
                // Exclusive creation prevents a repeated click from overwriting an existing file.
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
                throw error
            }
        }
        throw NSError(domain: "QuickMark", code: 2, userInfo: [NSLocalizedDescriptionKey: "文件名重复，请稍后重试。"])
    }
}
