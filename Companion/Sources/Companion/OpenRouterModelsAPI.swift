import Foundation

// Reads OpenRouter's public model catalog so Companion can offer fal/OpenRouter
// routes without making the user manually type every model slug.
final class OpenRouterModelsAPI {
    static let shared = OpenRouterModelsAPI()

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/models")!

    enum APIError: Error, LocalizedError {
        case requestFailed(Int, String)
        case invalidResponse
        case emptyCatalog

        var errorDescription: String? {
            switch self {
            case .requestFailed(let statusCode, let message):
                return "OpenRouter models request failed: HTTP \(statusCode): \(message)"
            case .invalidResponse:
                return "OpenRouter returned an invalid model catalog."
            case .emptyCatalog:
                return "OpenRouter returned no text models."
            }
        }
    }

    struct ModelsResponse: Decodable {
        let data: [Model]
    }

    struct Model: Decodable {
        let id: String
        let name: String?
        let architecture: Architecture?
    }

    struct Architecture: Decodable {
        let input_modalities: [String]?
        let output_modalities: [String]?
    }

    func listModels() async throws -> [UserSettings.RemoteCatalogModel] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed(httpResponse.statusCode, errorMessage(from: data))
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        let models = decoded.data.compactMap(catalogModel(from:))

        guard !models.isEmpty else { throw APIError.emptyCatalog }

        return models.sorted { lhs, rhs in
            lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    private func catalogModel(from model: Model) -> UserSettings.RemoteCatalogModel? {
        let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard !UserSettings.isUnavailableFalModel(id) else { return nil }

        let inputModalities = Set((model.architecture?.input_modalities ?? []).map { $0.lowercased() })
        let outputModalities = Set((model.architecture?.output_modalities ?? []).map { $0.lowercased() })

        // Companion runs chat/text generation. Exclude pure image/audio/etc. models.
        if !inputModalities.isEmpty, !inputModalities.contains("text") {
            return nil
        }
        if !outputModalities.isEmpty, !outputModalities.contains("text") {
            return nil
        }

        let name = model.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportsImages = inputModalities.contains("image") || UserSettings.isKnownVisionModel(id)

        return UserSettings.RemoteCatalogModel(
            id: id,
            name: name?.isEmpty == false ? name! : id,
            supportsImages: supportsImages
        )
    }

    private func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message.truncatedForDisplay()
            }
            if let message = json["message"] as? String {
                return message.truncatedForDisplay()
            }
        }

        return (String(data: data, encoding: .utf8) ?? "Unknown error").truncatedForDisplay()
    }
}

private extension String {
    func truncatedForDisplay(limit: Int = 220) -> String {
        guard count > limit else { return self }
        return "\(prefix(limit))..."
    }
}
