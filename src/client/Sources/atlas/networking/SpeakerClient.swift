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

extension SpeakerClient {
    func reinforce(profileID: Int, wavURL: URL) async throws -> SpeakerReinforceResponse {
        let boundary = UUID().uuidString
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            ("Content-Disposition: form-data; "
                + "name=\"audio\"; filename=\"utterance.wav\"\r\n").data(using: .utf8)!
        )
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wavURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let url = Config.toolServerURL
            .appendingPathComponent("speaker")
            .appendingPathComponent("\(profileID)")
            .appendingPathComponent("reinforce")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Config.speakerIdentificationTimeout
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw NSError(
                domain: "SpeakerClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Reinforcement request failed."]
            )
        }

        return try JSONDecoder().decode(SpeakerReinforceResponse.self, from: data)
    }

    func enrollAnonymous(wavURLs: [URL]) async throws -> SpeakerEnrollResponse {
        let boundary = UUID().uuidString
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"anonymous\"\r\n\r\n".data(using: .utf8)!)
        body.append("true\r\n".data(using: .utf8)!)

        for (index, wavURL) in wavURLs.enumerated() {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                ("Content-Disposition: form-data; "
                    + "name=\"audio\"; filename=\"sample-\(index).wav\"\r\n").data(using: .utf8)!
            )
            body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(try Data(contentsOf: wavURL))
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let url = Config.toolServerURL
            .appendingPathComponent("speaker")
            .appendingPathComponent("enroll")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Config.speakerIdentificationTimeout
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let bodyText = String(decoding: data, as: UTF8.self)
            throw NSError(
                domain: "SpeakerClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Anonymous enrollment failed: \(bodyText)"]
            )
        }

        return try JSONDecoder().decode(SpeakerEnrollResponse.self, from: data)
    }

    func promote(profileID: Int, name: String) async throws -> SpeakerEnrollResponse {
        let boundary = UUID().uuidString
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"name\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(name)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let url = Config.toolServerURL
            .appendingPathComponent("speaker")
            .appendingPathComponent("\(profileID)")
            .appendingPathComponent("promote")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Config.speakerIdentificationTimeout
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let bodyText = String(decoding: data, as: UTF8.self)
            throw NSError(
                domain: "SpeakerClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Promotion failed: \(bodyText)"]
            )
        }

        return try JSONDecoder().decode(SpeakerEnrollResponse.self, from: data)
    }
}

struct SpeakerEnrollResponse: Decodable, Sendable {
    let ok: Bool
    let profile: SpeakerProfileInfo?

    struct SpeakerProfileInfo: Decodable, Sendable {
        let id: Int
        let displayName: String
        let anonymous: Bool
        let sampleCount: Int

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case anonymous
            case sampleCount = "sample_count"
        }
    }
}
