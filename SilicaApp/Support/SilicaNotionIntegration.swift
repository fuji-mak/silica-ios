import Combine
import CryptoKit
import Foundation
import Security

enum SilicaAPIError: LocalizedError, Equatable {
    case invalidResponse
    case transport(String)
    case server(code: String, status: Int)
    case missingDestination

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return AppLanguage.current == .english ? "The server response was invalid." : "サーバーの応答を確認できませんでした。"
        case let .transport(message):
            return message
        case let .server(code, _):
            return apiErrorMessage(for: code)
        case .missingDestination:
            return AppLanguage.current == .english ? "Choose a Notion page first." : "先にNotionの保存先を選択してください。"
        }
    }

    private func apiErrorMessage(for code: String) -> String {
        if AppLanguage.current == .english {
            switch code {
            case "notion_not_connected": return "Connect Silica to Notion first."
            case "notion_reauthorization_required": return "Please reconnect Silica to Notion."
            case "notion_app_update_required": return "Update Silica to connect to Notion."
            case "invalid_oauth_completion": return "Restart the Notion connection from this device."
            case "rate_limited", "notion_rate_limited": return "Too many requests. Please try again later."
            default: return "Silica API error: \(code)"
            }
        }

        switch code {
        case "notion_not_connected": return "先にSilicaをNotionへ接続してください。"
        case "notion_reauthorization_required": return "Notionとの接続が切れています。再接続してください。"
        case "notion_app_update_required": return "Notionへ接続するにはSilicaをアップデートしてください。"
        case "invalid_oauth_completion": return "この端末からNotionとの接続をやり直してください。"
        case "rate_limited", "notion_rate_limited": return "リクエストが多すぎます。少し待ってから再試行してください。"
        default: return "Silica APIエラー: \(code)"
        }
    }
}

private struct SilicaAPIErrorResponse: Decodable {
    let error: String?
}

private struct SilicaCredentials: Codable {
    let installationId: String
    let installationSecret: String
}

private enum SilicaKeychain {
    private static let service = "com.fujimakitaketo.silica.api"
    private static let account = "installation-credentials"

    static func load() -> SilicaCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(SilicaCredentials.self, from: data)
    }

    static func save(_ credentials: SilicaCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SilicaAPIError.invalidResponse }
        } else if updateStatus != errSecSuccess {
            throw SilicaAPIError.invalidResponse
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct BootstrapResponse: Decodable {
    let installationId: String
    let installationSecret: String
}

struct SilicaNotionStatus: Decodable {
    let connected: Bool
    let workspace: Workspace?

    struct Workspace: Decodable {
        let name: String?
    }
}

struct SilicaNotionSearchResponse: Decodable {
    let results: [SilicaNotionItem]
}

struct SilicaNotionItem: Decodable, Identifiable, Hashable {
    let id: String
    let object: String?
    let title: [SilicaNotionText]?
    let properties: [String: SilicaNotionProperty]?

    var isDataSource: Bool {
        object == "data_source" || object == "database"
    }

    var displayTitle: String {
        let propertyTitle = properties?.values
            .compactMap { $0.title }
            .flatMap { $0 }
            .compactMap { $0.plainText }
            .joined()
        if let propertyTitle, propertyTitle.isEmpty == false {
            return propertyTitle
        }

        let topLevelTitle = title?.compactMap { $0.plainText }.joined() ?? ""
        if topLevelTitle.isEmpty == false {
            return topLevelTitle
        }
        return AppLanguage.current == .english ? "Untitled" : "無題のページ"
    }

    var typeLabel: String {
        if isDataSource {
            return AppLanguage.current == .english ? "Database" : "データベース"
        }
        return AppLanguage.current == .english ? "Page" : "ページ"
    }
}

struct SilicaNotionProperty: Decodable, Hashable {
    let title: [SilicaNotionText]?
}

struct SilicaNotionText: Decodable, Hashable {
    let plainText: String?

    enum CodingKeys: String, CodingKey {
        case plainText = "plain_text"
    }
}

struct SilicaNotionSyncResponse: Decodable {
    let mode: String
}

private struct NotionAuthorizeRequest: Encodable {
    let returnUrl: String
    let completionMode = "app"
}

private struct NotionCompleteRequest: Encodable {
    let completionToken: String
}

private struct NotionSearchRequest: Encodable {
    let query: String?
}

private struct NotionSyncRequest: Encodable {
    let markdown: String
    let date: String?
    let pageId: String?
    let parentPageId: String?
    let dataSourceId: String?
}

struct SilicaFeedbackPayload: Encodable {
    let kind: String
    let title: String
    let message: String
    let contactEmail: String?
    let appVersion: String?
    let osVersion: String?
    let deviceModel: String?
    let locale: String?
    let hasPro: Bool?
}

final class SilicaAPIClient: @unchecked Sendable {
    static let shared = SilicaAPIClient()

    private let baseURL = URL(string: "https://fuji-maki.me/api/silica")!
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    var hasStoredCredentials: Bool {
        SilicaKeychain.load() != nil
    }

    func bootstrap() async throws {
        let data = try await request(
            method: "POST",
            path: "/session/bootstrap",
            body: nil,
            credentials: nil
        )
        let response = try decoder.decode(BootstrapResponse.self, from: data)
        try SilicaKeychain.save(
            SilicaCredentials(
                installationId: response.installationId,
                installationSecret: response.installationSecret
            )
        )
    }

    func authorizationURL() async throws -> URL {
        let callbackScheme = Bundle.main.object(
            forInfoDictionaryKey: "SilicaURLScheme"
        ) as? String ?? "silica"
        let body = try encoder.encode(
            NotionAuthorizeRequest(returnUrl: "\(callbackScheme)://notion/callback")
        )
        let data = try await signedRequest(method: "POST", path: "/notion/authorize", body: body)
        let response = try decoder.decode(AuthorizationResponse.self, from: data)
        guard let url = URL(string: response.authorizationUrl) else {
            throw SilicaAPIError.invalidResponse
        }
        return url
    }

    func status() async throws -> SilicaNotionStatus {
        let data = try await signedRequest(method: "GET", path: "/notion/status", body: nil)
        return try decoder.decode(SilicaNotionStatus.self, from: data)
    }

    func completeAuthorization(token: String) async throws {
        let body = try encoder.encode(NotionCompleteRequest(completionToken: token))
        _ = try await signedRequest(method: "POST", path: "/notion/complete", body: body)
    }

    func search(query: String? = nil) async throws -> SilicaNotionSearchResponse {
        let body = try encoder.encode(NotionSearchRequest(query: query))
        let data = try await signedRequest(method: "POST", path: "/notion/search", body: body)
        return try decoder.decode(SilicaNotionSearchResponse.self, from: data)
    }

    func sync(
        markdown: String,
        date: String? = nil,
        pageId: String? = nil,
        parentPageId: String? = nil,
        dataSourceId: String? = nil
    ) async throws -> SilicaNotionSyncResponse {
        let body = try encoder.encode(
            NotionSyncRequest(
                markdown: markdown,
                date: date,
                pageId: pageId,
                parentPageId: parentPageId,
                dataSourceId: dataSourceId
            )
        )
        let data = try await signedRequest(method: "POST", path: "/notion/sync", body: body)
        return try decoder.decode(SilicaNotionSyncResponse.self, from: data)
    }

    func disconnect() async throws {
        _ = try await signedRequest(method: "DELETE", path: "/notion/disconnect", body: nil)
    }

    func sendFeedback(_ payload: SilicaFeedbackPayload) async throws {
        let body = try encoder.encode(payload)
        _ = try await signedRequest(method: "POST", path: "/feedback", body: body)
    }

    func clearCredentials() {
        SilicaKeychain.delete()
    }

    private struct AuthorizationResponse: Decodable {
        let authorizationUrl: String
    }

    private func signedRequest(method: String, path: String, body: Data?) async throws -> Data {
        guard let credentials = SilicaKeychain.load() else {
            try await bootstrap()
            guard let credentials = SilicaKeychain.load() else {
                throw SilicaAPIError.invalidResponse
            }
            return try await signedRequest(method: method, path: path, body: body, credentials: credentials)
        }
        return try await signedRequest(method: method, path: path, body: body, credentials: credentials)
    }

    private func signedRequest(
        method: String,
        path: String,
        body: Data?,
        credentials: SilicaCredentials
    ) async throws -> Data {
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = randomToken(byteCount: 18)
        let bodyText = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let requestPath = baseURL.appendingPathComponent(
            path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ).path
        let signingPayload = [
            String(timestamp),
            nonce,
            method.uppercased(),
            requestPath,
            bodyText,
        ].joined(separator: "\n")

        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method.uppercased()
        request.httpBody = body
        request.setValue(credentials.installationId, forHTTPHeaderField: "X-Silica-Installation")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Silica-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Silica-Nonce")
        request.setValue(
            hmacBase64URL(secret: credentials.installationSecret, message: signingPayload),
            forHTTPHeaderField: "X-Silica-Signature"
        )
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    private func request(
        method: String,
        path: String,
        body: Data?,
        credentials: SilicaCredentials?
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method.uppercased()
        request.httpBody = body
        if let credentials {
            request.setValue(credentials.installationId, forHTTPHeaderField: "X-Silica-Installation")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SilicaAPIError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let code = (try? decoder.decode(SilicaAPIErrorResponse.self, from: data).error) ?? "request_failed"
                throw SilicaAPIError.server(code: code, status: httpResponse.statusCode)
            }
            return data
        } catch let error as SilicaAPIError {
            throw error
        } catch {
            throw SilicaAPIError.transport(
                AppLanguage.current == .english
                    ? "Could not connect to Silica."
                    : "Silicaサーバーに接続できませんでした。"
            )
        }
    }

    private func hmacBase64URL(secret: String, message: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func randomToken(byteCount: Int) -> String {
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class SilicaNotionStore: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var workspaceName: String?
    @Published private(set) var isLoading = false
    @Published private(set) var searchResults: [SilicaNotionItem] = []
    @Published private(set) var selectedItem: SilicaNotionItem?
    @Published var errorMessage: String?

    private let client: SilicaAPIClient
    private let defaults = UserDefaults.standard
    private var automaticSyncInFlight = false
    #if DEBUG
    private var shouldForceAutomaticSyncForTest =
        DebugLaunchConfiguration.testsNotionAutomaticExport
    #endif

    private let selectedIDKey = "silica.notion.selectedDestinationID"
    private let selectedTitleKey = "silica.notion.selectedDestinationTitle"
    private let selectedObjectKey = "silica.notion.selectedDestinationObject"
    private let automaticSyncDigestsByDateKey = "silica.notion.automaticSync.digestsByDate"

    var selectedDestinationTitle: String? {
        selectedItem?.displayTitle
    }

    var hasSelectedDestination: Bool {
        selectedItem != nil
    }

    var canSyncAutomatically: Bool {
        client.hasStoredCredentials && hasSelectedDestination
    }

    init(client: SilicaAPIClient = .shared) {
        self.client = client
        loadSavedSelection()
    }

    func refresh() async {
        guard client.hasStoredCredentials else {
            isConnected = false
            workspaceName = nil
            return
        }

        do {
            let status = try await client.status()
            isConnected = status.connected
            workspaceName = status.workspace?.name
        } catch {
            isConnected = false
            errorMessage = error.localizedDescription
        }
    }

    func authorizationURL() async throws -> URL {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            return try await client.authorizationURL()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func handleIncomingURL(_ url: URL) {
        let callbackScheme = Bundle.main.object(forInfoDictionaryKey: "SilicaURLScheme") as? String ?? "silica"
        guard url.scheme == callbackScheme, url.host == "notion", url.path == "/callback" else {
            return
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let status = items?.first(where: { $0.name == "notion" })?.value
        if status == "pending", let token = items?.first(where: { $0.name == "completionToken" })?.value {
            errorMessage = nil
            Task {
                isLoading = true
                defer { isLoading = false }
                do {
                    try await client.completeAuthorization(token: token)
                    await refresh()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } else if status == "denied" {
            errorMessage = AppLanguage.current == .english ? "Notion connection was cancelled." : "Notionとの接続がキャンセルされました。"
        } else {
            errorMessage = AppLanguage.current == .english ? "Notion connection failed." : "Notionとの接続に失敗しました。"
        }
    }

    func loadSearch(query: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let response = try await client.search(query: query)
            searchResults = response.results.filter { $0.object == "page" || $0.isDataSource }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ item: SilicaNotionItem) {
        selectedItem = item
        defaults.set(item.id, forKey: selectedIDKey)
        defaults.set(item.displayTitle, forKey: selectedTitleKey)
        defaults.set(item.object ?? "page", forKey: selectedObjectKey)
    }

    func sync(markdown: String, date: String) async throws -> SilicaNotionSyncResponse {
        guard let selectedItem else {
            throw SilicaAPIError.missingDestination
        }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            if selectedItem.isDataSource {
                return try await client.sync(markdown: markdown, date: date, dataSourceId: selectedItem.id)
            }
            return try await client.sync(markdown: markdown, date: date, parentPageId: selectedItem.id)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func syncAutomaticallyIfNeeded(
        markdown: String,
        date: String
    ) async throws -> SilicaNotionSyncResponse? {
        guard client.hasStoredCredentials else {
            #if DEBUG
            if DebugLaunchConfiguration.testsNotionAutomaticExport {
                print("SILICA_NOTION_AUTO_TEST=skipped reason=no_credentials")
            }
            #endif
            return nil
        }
        guard let selectedItem else {
            #if DEBUG
            if DebugLaunchConfiguration.testsNotionAutomaticExport {
                print("SILICA_NOTION_AUTO_TEST=skipped reason=no_destination")
            }
            #endif
            return nil
        }

        if automaticSyncInFlight {
            for _ in 0..<120 where automaticSyncInFlight {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard automaticSyncInFlight == false else {
            #if DEBUG
            if DebugLaunchConfiguration.testsNotionAutomaticExport {
                print("SILICA_NOTION_AUTO_TEST=skipped reason=in_flight_timeout")
            }
            #endif
            return nil
        }

        let digest = automaticSyncDigest(
            destinationID: selectedItem.id,
            markdown: markdown
        )
        let digestCacheKey = "\(selectedItem.id)|\(date)"
        let digestsByDate = defaults.dictionary(
            forKey: automaticSyncDigestsByDateKey
        ) as? [String: String] ?? [:]
        #if DEBUG
        let shouldForceSync = shouldForceAutomaticSyncForTest
        #else
        let shouldForceSync = false
        #endif
        guard shouldForceSync || digestsByDate[digestCacheKey] != digest else {
            #if DEBUG
            if DebugLaunchConfiguration.testsNotionAutomaticExport {
                print("SILICA_NOTION_AUTO_TEST=skipped reason=unchanged")
            }
            #endif
            return nil
        }
        automaticSyncInFlight = true
        defer { automaticSyncInFlight = false }

        if isConnected == false {
            let status = try await client.status()
            isConnected = status.connected
            workspaceName = status.workspace?.name
        }
        guard isConnected else {
            #if DEBUG
            if DebugLaunchConfiguration.testsNotionAutomaticExport {
                print("SILICA_NOTION_AUTO_TEST=skipped reason=not_connected")
            }
            #endif
            return nil
        }

        let response = try await sync(markdown: markdown, date: date)
        var updatedDigestsByDate = digestsByDate
        updatedDigestsByDate[digestCacheKey] = digest
        defaults.set(updatedDigestsByDate, forKey: automaticSyncDigestsByDateKey)
        #if DEBUG
        shouldForceAutomaticSyncForTest = false
        if DebugLaunchConfiguration.testsNotionAutomaticExport {
            print("SILICA_NOTION_AUTO_TEST=success mode=\(response.mode) date=\(date)")
        }
        #endif
        return response
    }

    func disconnect() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.disconnect()
            client.clearCredentials()
            isConnected = false
            workspaceName = nil
            searchResults = []
            selectedItem = nil
            defaults.removeObject(forKey: selectedIDKey)
            defaults.removeObject(forKey: selectedTitleKey)
            defaults.removeObject(forKey: selectedObjectKey)
            defaults.removeObject(forKey: automaticSyncDigestsByDateKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func automaticSyncDigest(
        destinationID: String,
        markdown: String
    ) -> String {
        let data = Data("\(destinationID)\n\(markdown)".utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func loadSavedSelection() {
        guard let id = defaults.string(forKey: selectedIDKey),
              let title = defaults.string(forKey: selectedTitleKey) else {
            return
        }
        selectedItem = SilicaNotionItem(
            id: id,
            object: defaults.string(forKey: selectedObjectKey) ?? "page",
            title: [SilicaNotionText(plainText: title)],
            properties: nil
        )
    }
}
