import Foundation

/// How a slash date such as "3/10" in an email is read (`mail.dateOrder`, Settings ▸ Mail ▸
/// Reading criteria). Absent means `.mdy`, today's reading for every existing install.
package enum SlashDateOrder: String, Codable, Sendable, CaseIterable {
    case mdy        // month first: 3/10 = March 10
    case dmy        // day first: 3/10 = 3 October
    case auto       // follow the Mac's region

    /// `.mdy` or `.dmy`: `.auto` becomes the order `locale` writes numeric dates in.
    package func resolved(locale: Locale = .current) -> SlashDateOrder {
        guard self == .auto else { return self }
        let format = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: locale) ?? "M/d"
        guard let d = format.firstIndex(of: "d"), let m = format.firstIndex(of: "M") else { return .mdy }
        return d < m ? .dmy : .mdy
    }
}
