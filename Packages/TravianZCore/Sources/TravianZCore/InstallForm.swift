import Foundation

/// Reads the default values of the first `<form>` of an HTML page – what a browser would submit unchanged:
/// text/hidden/password inputs (`value`), selects (the `selected` option, else the first enabled one).
/// Disabled inputs, checkboxes, radios and buttons are skipped.
///
/// Same rules as `FormDefaults` in scripts/tz_install.py (the test compares both on a captured installer page).
public enum InstallForm {
    public static func defaults(in html: String) -> [String: String] {
        guard let start = html.range(of: "<form", options: .caseInsensitive) else { return [:] }
        let rest = html[start.lowerBound...]
        let end = rest.range(of: "</form>", options: .caseInsensitive)?.lowerBound ?? rest.endIndex
        let form = String(rest[..<end])

        var values: [String: String] = [:]
        var select: String?
        var firstOption: String?
        var chosenOption: String?

        let ns = form as NSString
        for match in tagPattern.matches(in: form, range: NSRange(location: 0, length: ns.length)) {
            let closing = ns.substring(with: match.range(at: 1)) == "/"
            let tag = ns.substring(with: match.range(at: 2)).lowercased()
            let attrs = attributes(ns.substring(with: match.range(at: 3)))

            switch (tag, closing) {
            case ("input", false):
                guard let name = attrs["name"] ?? nil, !name.isEmpty else { continue }
                let type = (attrs["type"] ?? nil) ?? "text"
                if ["submit", "button", "checkbox", "radio"].contains(type) || attrs.keys.contains("disabled") { continue }
                values[name] = (attrs["value"] ?? nil) ?? ""
            case ("select", false):
                guard let name = attrs["name"] ?? nil, !name.isEmpty else { continue }
                select = name
                firstOption = nil
                chosenOption = nil
            case ("option", false):
                guard select != nil else { continue }
                let value = (attrs["value"] ?? nil) ?? ""
                if firstOption == nil && !attrs.keys.contains("disabled") { firstOption = value }
                if attrs.keys.contains("selected") && chosenOption == nil { chosenOption = value }
            case ("select", true):
                if let name = select {
                    values[name] = chosenOption ?? firstOption ?? ""
                    select = nil
                }
            default:
                continue
            }
        }
        return values
    }

    private static let tagPattern = try! NSRegularExpression(
        pattern: "<(/?)(input|select|option)\\b([^>]*)>", options: [.caseInsensitive])
    private static let attributePattern = try! NSRegularExpression(
        pattern: "([^\\s=/>\"']+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+)))?", options: [])

    /// Attribute name (lowercased) → value; `nil` value for a bare attribute such as `selected`.
    static func attributes(_ text: String) -> [String: String?] {
        var result: [String: String?] = [:]
        let ns = text as NSString
        for m in attributePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            var value: String?
            for group in 2...4 where m.range(at: group).location != NSNotFound {
                value = decodeEntities(ns.substring(with: m.range(at: group)))
                break
            }
            if result[name] == nil { result[name] = .some(value) }
        }
        return result
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": "\u{00A0}"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        var decoded = ""
        var last = 0
        for m in numeric.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            decoded += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let code = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                decoded.unicodeScalars.append(scalar)
            } else {
                decoded += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        decoded += ns.substring(from: last)
        return decoded.replacingOccurrences(of: "&amp;", with: "&")
    }
}
