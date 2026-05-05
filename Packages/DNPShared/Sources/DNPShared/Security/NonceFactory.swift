import Foundation

public enum NonceFactory {
    /// 16 random bytes, base64-encoded — short, URL-safe-ish.
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let r = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(r == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
    }
}
