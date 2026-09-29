import Foundation

public enum UpdateKey {
    /// A Sparkle EdDSA public key is 32 bytes, base64-encoded. Anything else (empty, the
    /// "REPLACE_WITH…" placeholder) means updates aren't set up and the updater stays off.
    public static func isReal(_ key: String) -> Bool {
        Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines))?.count == 32
    }
}
