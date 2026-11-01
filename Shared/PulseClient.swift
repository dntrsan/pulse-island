import Foundation
import Security

enum PulseError: LocalizedError, Equatable {
    case unauthorized
    case badURL
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Pulse の登録が外れています。もう一度ペアリングしてください"
        case .badURL: "URL の形が正しくありません"
        case .server(let m): m
        case .network(let m): m
        }
    }
}

/// PC の Claude Pulse と話す。鍵はクッキー（pulse_dev）として毎回付ける
struct PulseClient {
    let base: URL
    let token: String

    /// 「desktop.xxx.ts.net」のような入力も https:// を補って受け付ける
    static func normalize(_ text: String?) -> URL? {
        var s = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host() != nil else { return nil }
        return url
    }

    /// PC で出した 6 桁のコードで端末を登録し、鍵を受け取る
    static func pair(base: URL, code: String, name: String) async throws -> String {
        var req = URLRequest(url: base.appending(path: "api/pair"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("island", forHTTPHeaderField: "x-pulse-client")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "name": name])
        let (data, resp) = try await send(req)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard resp.statusCode == 200 else {
            throw PulseError.server(body?["error"] as? String ?? "登録できませんでした（HTTP \(resp.statusCode)）")
        }
        guard let token = body?["token"] as? String, !token.isEmpty else {
            throw PulseError.server("Pulse が古いようです。PC の Pulse を更新してください")
        }
        return token
    }

    /// 要約を取る。wait に今の版を渡すと、変わるまで（最長 25 秒）待ってから返ってくる
    func island(wait: String?) async throws -> IslandSnapshot {
        var comps = URLComponents(url: base.appending(path: "api/island"), resolvingAgainstBaseURL: false)
        if let wait { comps?.queryItems = [URLQueryItem(name: "wait", value: wait)] }
        guard let url = comps?.url else { throw PulseError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 40
        req.httpShouldHandleCookies = false
        req.setValue("pulse_dev=\(token)", forHTTPHeaderField: "Cookie")
        req.setValue("island", forHTTPHeaderField: "x-pulse-client")
        let (data, resp) = try await Self.send(req)
        if resp.statusCode == 401 { throw PulseError.unauthorized }
        guard resp.statusCode == 200 else { throw PulseError.server("Pulse がエラーを返しました（HTTP \(resp.statusCode)）") }
        do {
            return try JSONDecoder().decode(IslandSnapshot.self, from: data)
        } catch {
            throw PulseError.server("Pulse の返事を読めませんでした")
        }
    }

    private static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw PulseError.network("返事がありません") }
            return (data, http)
        } catch let e as PulseError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PulseError.network("Pulse につながりません（Tailscale はオンですか？）")
        }
    }
}

/// 鍵はキーチェーンに置く（アプリとウィジェットはそれぞれ自分の分を持つ）
enum Keychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "pulse-island" }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // 画面ロック中でも裏で通信できるように、起動後 1 回ロックを外したあとは読めるようにする
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
