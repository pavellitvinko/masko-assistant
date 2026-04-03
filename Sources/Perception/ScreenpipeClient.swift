import Foundation

class ScreenpipeClient {
    private let baseURL: URL

    init(baseURL: String = Constants.screenpipeBaseURL) {
        self.baseURL = URL(string: baseURL)!
    }

    struct SearchRequest {
        let limit: Int
        let appName: String?
        let windowName: String?
        let minLength: Int?
    }

    struct ScreenpipeHealth {
        let isHealthy: Bool
        let lastAudioTimestamp: String?

        var isAudioCaptureDetected: Bool {
            guard let lastAudioTimestamp else { return false }
            return !lastAudioTimestamp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private struct HealthResponse: Codable {
        let status: String?
        let last_audio_timestamp: String?
    }

    func fetchHealth() async -> ScreenpipeHealth? {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return ScreenpipeHealth(isHealthy: false, lastAudioTimestamp: nil)
            }

            let payload = try? JSONDecoder().decode(HealthResponse.self, from: data)
            return ScreenpipeHealth(
                isHealthy: true,
                lastAudioTimestamp: payload?.last_audio_timestamp
            )
        } catch {
            return nil
        }
    }

    func checkHealth() async -> Bool {
        (await fetchHealth())?.isHealthy == true
    }

    struct ScreenpipeResponse: Codable {
        let data: [ScreenpipeDataItem]
    }

    struct ScreenpipeDataItem: Codable {
        let content: ScreenpipeContext?
        let app_name: String?
        let window_name: String?
        let text: String?
        let timestamp: String?
        let focused: Bool?

        var resolvedContext: ScreenpipeContext? {
            if let content {
                return content
            }

            guard let appName = app_name,
                  let windowName = window_name,
                  let text,
                  let timestamp else {
                return nil
            }

            return ScreenpipeContext(
                app_name: appName,
                window_name: windowName,
                text: text,
                timestamp: timestamp,
                focused: focused
            )
        }
    }

    struct ScreenpipeContext: Codable {
        let app_name: String
        let window_name: String
        let text: String
        let timestamp: String
        let focused: Bool?
    }

    func getRecentContext(limit: Int = 3) async throws -> [ScreenpipeContext] {
        try await getRecentContext(
            request: SearchRequest(
                limit: limit,
                appName: nil,
                windowName: nil,
                minLength: nil
            )
        )
    }

    func getRecentContext(request: SearchRequest) async throws -> [ScreenpipeContext] {
        let url = baseURL.appendingPathComponent("search")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "limit", value: "\(request.limit)"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "content_type", value: "ocr")
        ]

        if let appName = request.appName,
           !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "app_name", value: appName))
        }

        if let windowName = request.windowName,
           !windowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "window_name", value: windowName))
        }

        if let minLength = request.minLength {
            queryItems.append(URLQueryItem(name: "min_length", value: "\(minLength)"))
        }

        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 3.0

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(ScreenpipeResponse.self, from: data)
        return response.data.compactMap(\.resolvedContext)
    }
}
