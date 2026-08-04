import Foundation

final class SpeakerClient: @unchecked Sendable {
    func identify(_ wavURL: URL) async throws -> SpeakerIdentificationResponse {
        let boundary = UUID().uuidString
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            ("Content-Disposition: form-data; "
                + "name=\"audio\"; filename=\"utterance.wav\"\r\n").data(using: .utf8)!
        )
        body.append(
            "Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!
        )
        body.append(try Data(contentsOf: wavURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let url = Config.toolServerURL
            .appendingPathComponent("speaker")
            .appendingPathComponent("identify")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Config.speakerIdentificationTimeout

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
            let bodyText = String(decoding: data, as: UTF8.self)

            throw NSError(
                domain: "SpeakerClient",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Speaker identification request failed: \(bodyText)"
                ]
            )
        }

        return try JSONDecoder().decode(
            SpeakerIdentificationResponse.self,
            from: data
        )
    }
}
