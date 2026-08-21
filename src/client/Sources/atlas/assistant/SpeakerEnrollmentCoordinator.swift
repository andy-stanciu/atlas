import Foundation

final class SpeakerEnrollmentCoordinator {
    private let speakerClient: SpeakerClient
    private let llm: LLMClient

    private var anonymousProfileID: Int?
    private var latestUnknownSpeakerWAV: URL?
    private(set) var isAwaitingName = false

    private var nameRequestPending = false

    var hasPendingNameRequest: Bool {
        nameRequestPending && !isAwaitingName
    }

    init(speakerClient: SpeakerClient, llm: LLMClient) {
        self.speakerClient = speakerClient
        self.llm = llm
    }

    func processTurnResult(
        speakerResponse: SpeakerIdentificationResponse?,
        wavURL: URL
    ) async -> Bool {
        guard !isAwaitingName else {
            return false
        }

        guard let speakerResponse else {
            return false
        }

        switch speakerResponse.status {
        case .known:
            if let identity = speakerResponse.identity, identity.anonymous {
                anonymousProfileID = identity.id
                return await reinforceIfEligible(
                    speakerResponse: speakerResponse,
                    wavURL: wavURL
                )
            }

            anonymousProfileID = nil
            clearLatestClip()
            return await reinforceIfEligible(
                speakerResponse: speakerResponse,
                wavURL: wavURL
            )

        case .uncertain, .unknown:
            guard let durationSeconds = speakerResponse.durationSeconds,
                durationSeconds >= Config.speakerEnrollmentMinimumClipSeconds
            else {
                return false
            }

            replaceLatestClip(with: wavURL)

            if anonymousProfileID == nil {
                enrollAnonymously(wavURL: wavURL)
            }

            return false
        }
    }

    func beginNameRequest() -> Bool {
        guard nameRequestPending, !isAwaitingName else { return false }
        nameRequestPending = false
        isAwaitingName = true
        return true
    }

    func rescheduleNameRequest() {
        guard isAwaitingName else {
            return
        }
        isAwaitingName = false
        nameRequestPending = true
    }

    func resolveNameResponse(userText: String) async -> String {
        isAwaitingName = false

        let extractedName = try? await llm.extractSpeakerName(from: userText)

        if let extractedName, let profileID = anonymousProfileID {
            Task { [speakerClient] in
                do {
                    let result = try await speakerClient.promote(
                        profileID: profileID, name: extractedName
                    )
                    if result.ok {
                        Log.speaker(
                            "promoted anonymous profile \(profileID) to: \(extractedName)"
                        )
                    }
                } catch {
                    Log.speaker("promotion failed: \(error.localizedDescription)")
                }
            }
            anonymousProfileID = nil
            clearLatestClip()
            return SystemPrompts.speakerEnrollmentAcknowledgementInstruction
        }

        return SystemPrompts.speakerEnrollmentDeclineInstruction
    }

    private func armNameRequest() {
        guard !nameRequestPending else {
            return
        }
        nameRequestPending = true
    }

    private func enrollAnonymously(wavURL: URL) {
        let enrollCopy = wavURL.deletingLastPathComponent()
            .appendingPathComponent("enroll-anon-\(UUID().uuidString).wav")
        try? FileManager.default.copyItem(at: wavURL, to: enrollCopy)

        Task { [speakerClient] in
            defer { try? FileManager.default.removeItem(at: enrollCopy) }
            do {
                let result = try await speakerClient.enrollAnonymous(
                    wavURLs: [enrollCopy]
                )
                if let profile = result.profile {
                    Log.speaker(
                        "anonymous profile enrolled: id=\(profile.id) "
                            + "samples=\(profile.sampleCount)"
                    )
                }
            } catch {
                Log.speaker("anonymous enrollment failed: \(error.localizedDescription)")
            }
        }
    }

    private func reinforceIfEligible(
        speakerResponse: SpeakerIdentificationResponse,
        wavURL: URL
    ) async -> Bool {
        guard let similarity = speakerResponse.similarity,
            let profileID = speakerResponse.profileID,
            let durationSeconds = speakerResponse.durationSeconds,
            similarity >= Config.speakerReinforceThreshold,
            durationSeconds >= Config.speakerReinforceMinimumDurationSeconds
        else {
            return false
        }

        let reinforceCopy = wavURL.deletingLastPathComponent()
            .appendingPathComponent("reinforce-\(UUID().uuidString).wav")
        try? FileManager.default.copyItem(at: wavURL, to: reinforceCopy)

        defer { try? FileManager.default.removeItem(at: reinforceCopy) }

        do {
            let result = try await speakerClient.reinforce(
                profileID: profileID, wavURL: reinforceCopy
            )
            if result.accepted {
                Log.speaker(
                    "reinforced profile \(profileID) "
                        + "(similarity=\(similarity), duration=\(durationSeconds)s)"
                )
            }
            if result.askIdentification == true {
                armNameRequest()
            }
            return result.askIdentification == true
        } catch {
            Log.speaker("reinforcement failed: \(error.localizedDescription)")
            return false
        }
    }

    private func replaceLatestClip(with wavURL: URL) {
        if let previous = latestUnknownSpeakerWAV {
            try? FileManager.default.removeItem(at: previous)
        }

        let persistedCopy = wavURL.deletingLastPathComponent()
            .appendingPathComponent("enroll-\(UUID().uuidString).wav")
        try? FileManager.default.copyItem(at: wavURL, to: persistedCopy)
        latestUnknownSpeakerWAV = persistedCopy
    }

    private func clearLatestClip() {
        if let wav = latestUnknownSpeakerWAV {
            try? FileManager.default.removeItem(at: wav)
            latestUnknownSpeakerWAV = nil
        }
    }
}
