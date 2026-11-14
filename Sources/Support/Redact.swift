import Foundation

/// Removes secrets from text that leaves the Mac (Export Diagnostics).
public enum Redact {
    /// Subsonic auth parameters and other credentials in URLs, headers and JSON.
    private static let patterns = [
        #"(?i)([?&](?:u|t|s|p|password|token|salt|apiKey|jwt)=)[^&\s"']+"#,
        #"(?i)("(?:password|token|salt|apiKey|secret|jwt)"\s*:\s*")[^"]*"#,
        #"(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+"#,
    ]

    public static func secrets(in text: String) -> String {
        patterns.reduce(text) { text, pattern in
            text.replacingOccurrences(of: pattern, with: "$1[redacted]", options: .regularExpression)
        }
    }
}
