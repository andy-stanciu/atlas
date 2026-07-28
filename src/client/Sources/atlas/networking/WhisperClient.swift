import Foundation

final class WhisperClient {
    func transcribe(_ wavURL: URL) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()

        func addTextField(_ name: String, _ value: String) {
            let header =
                "Content-Disposition: form-data; "
                + "name=\"\(name)\"\r\n\r\n"

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(header.data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        addTextField("model", "tiny")
        addTextField("language", "en")
        addTextField("response_format", "json")
        addTextField("temperature", "0")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            (
                "Content-Disposition: form-data; "
                    + "name=\"file\"; filename=\"utterance.wav\"\r\n"
            ).data(using: .utf8)!
        )
        body.append(
            "Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!
        )
        body.append(try Data(contentsOf: wavURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: Config.whisperURL)
        request.httpMethod = "POST"

        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard
            let http = response as? HTTPURLResponse,
            200..<300 ~= http.statusCode
        else {
            throw NSError(
                domain: "WhisperKit",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "WhisperKit transcription request failed."
                ]
            )
        }

        return try JSONDecoder()
            .decode(WhisperResponse.self, from: data)
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}