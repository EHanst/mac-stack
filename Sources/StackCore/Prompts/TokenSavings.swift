import Foundation

public enum TokenSavings {
    public static func percent(plain: Int, compact: Int) -> Int {
        guard plain > 0 else { return 0 }
        let saving = plain - compact
        guard saving > 0 else { return 0 }
        return Int((Double(saving) / Double(plain) * 100).rounded())
    }
}
