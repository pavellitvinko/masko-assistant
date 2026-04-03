import Foundation

class OllamaClient {
    private let baseURL: URL
    private let session: URLSession
    private let model: String

    init(
        baseURL: String = Constants.ollamaBaseURL,
        model: String = Constants.defaultOllamaModel
    ) {
        self.baseURL = URL(string: baseURL)!
        self.model = model
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 4.0
        configuration.timeoutIntervalForResource = 10.0
        self.session = URLSession(configuration: configuration)
    }

    func checkHealth() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    struct GenerateRequest: Codable {
        let model: String
        let prompt: String
        let stream: Bool
        let system: String?
        let template: String?
    }

    struct GenerateResponse: Codable {
        let response: String
        let done: Bool
    }

    func generate(prompt: String, system: String? = nil) async throws -> String {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GenerateRequest(
            model: self.model,
            prompt: prompt,
            stream: false,
            system: system,
            template: nil
        )

        let encoder = JSONEncoder()
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "OllamaClient", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoder = JSONDecoder()
        let result = try decoder.decode(GenerateResponse.self, from: data)
        return result.response
    }
}
