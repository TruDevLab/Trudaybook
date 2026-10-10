import CryptoKit
import Foundation

/// Ответ на проверку Digest (RFC 2617, RFC 8760): заголовок Authorization
/// или Proxy-Authorization по вызову из 401 или 407.
///
/// Пароль в сеть не уходит — только хэш с одноразовым `nonce` сервера.
public enum SIPDigest {
    public static func authorization(
        challenge header: String, method: String, uri: String,
        username: String, password: String, nc: Int = 1, cnonce: String = SIPHeader.token(16)
    ) -> String? {
        let fields = SIPHeader.challenge(header)
        guard header.lowercased().hasPrefix("digest"), let realm = fields["realm"], let nonce = fields["nonce"] else { return nil }
        let algorithm = (fields["algorithm"] ?? "MD5").uppercased()
        let hash: (String) -> String
        switch algorithm {
        case "MD5", "MD5-SESS": hash = md5
        case "SHA-256", "SHA-256-SESS": hash = sha256
        default: return nil
        }
        // qop: из предложенных берём «auth»; «auth-int» без «auth» не умеем.
        let offered = (fields["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let qop: String? = offered.isEmpty ? nil : (offered.contains("auth") ? "auth" : nil)
        if !offered.isEmpty, qop == nil { return nil }

        var ha1 = hash("\(username):\(realm):\(password)")
        if algorithm.hasSuffix("-SESS") { ha1 = hash("\(ha1):\(nonce):\(cnonce)") }
        let ha2 = hash("\(method):\(uri)")
        let count = String(format: "%08x", nc)
        let response = qop.map { hash("\(ha1):\(nonce):\(count):\(cnonce):\($0):\(ha2)") } ?? hash("\(ha1):\(nonce):\(ha2)")

        var parts = [
            "username=\"\(username)\"", "realm=\"\(realm)\"", "nonce=\"\(nonce)\"",
            "uri=\"\(uri)\"", "response=\"\(response)\"", "algorithm=\(fields["algorithm"] ?? "MD5")",
        ]
        if let qop { parts += ["qop=\(qop)", "nc=\(count)", "cnonce=\"\(cnonce)\""] }
        if let opaque = fields["opaque"] { parts.append("opaque=\"\(opaque)\"") }
        return "Digest " + parts.joined(separator: ", ")
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
