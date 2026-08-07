import Foundation

final class SpeakerEnrollmentCoordinator {
    private let speakerClient: SpeakerClient
    private let ollama: OllamaClient

    private var substantiveUnknownTurnCount = 0
    private var latestUnknownSpeakerWAV: URL?
    private(set) var isAwaitingName = false

    init(speakerClient: SpeakerClient, ollama: OllamaClient) {
        self.speakerClient = speakerClient
        self.ollama = ollama
    }

    /// Call once per ordinary turn. Returns true if a name should now be
    /// requested via a guaranteed follow-up utterance after this turn's
    /// reply finishes (see `beginNameRequest`).
    func processTurnResult(
        speakerResponse: SpeakerIdentificationResponse?,
        wavURL: URL
    ) -> Bool {
        guard !isAwaitingName else {
            return false
        }

        if let speakerResponse, speakerResponse.status == .known {
            resetUnknownTracking()
            reinforceIfEligible(speakerResponse: speakerResponse, wavURL: wavURL)
            return false
        }

        guard let speakerResponse, speakerResponse.status != .known else {
            return false
        }

        if let durationSeconds = speakerResponse.durationSeconds,
            durationSeconds >= Config.speakerEnrollmentMinimumClipSeconds
        {
            substantiveUnknownTurnCount += 1
            replaceLatestClip(with: wavURL)
        }

        print(
            "[speaker] substantive streak: \(substantiveUnknownTurnCount)/"
                + "\(Config.speakerEnrollmentRequiredTurns)"
        )

        return substantiveUnknownTurnCount >= Config.speakerEnrollmentRequiredTurns
    }

    /// Call after the main reply for this turn has finished playing, only
    /// if `processTurnResult` returned true. Generates the actual question
    /// text and commits to `isAwaitingName` only once we have something to
    /// say — if generation fails, returns nil and the streak is left intact
    /// so we simply try again on a future turn.
    func beginNameRequest() async -> String? {
        do {
            let prompt = try await ollama.generateSpeakerNameRequest()
            guard !prompt.isEmpty else {
                return nil
            }
            isAwaitingName = true
            return prompt
        } catch {
            print("[speaker] failed to generate name request: \(error.localizedDescription)")
            return nil
        }
    }

    /// Call for the turn immediately following a name request (i.e.
    /// when `isAwaitingName` was true), with the user's reply.
    ///
    /// Returns the instruction to use for this turn's
    /// acknowledgement/decline reply. Always resets internal state,
    /// whether or not a name was actually extracted.
    func resolveNameResponse(userText: String) async -> String {
        isAwaitingName = false
        let enrollmentWAV = latestUnknownSpeakerWAV
        latestUnknownSpeakerWAV = nil
        substantiveUnknownTurnCount = 0

        let extractedName = try? await ollama.extractSpeakerName(from: userText)

        if let extractedName, let enrollmentWAV {
            Task { [speakerClient] in
                do {
                    _ = try await speakerClient.enroll(
                        name: extractedName, wavURLs: [enrollmentWAV]
                    )
                    print("[speaker] enrolled new profile: \(extractedName)")
                } catch {
                    print("[speaker] enrollment failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: enrollmentWAV)
            }
            return SystemPrompts.speakerEnrollmentAcknowledgementInstruction
        }

        if let enrollmentWAV {
            try? FileManager.default.removeItem(at: enrollmentWAV)
        }
        return SystemPrompts.speakerEnrollmentDeclineInstruction
    }

    private func resetUnknownTracking() {
        substantiveUnknownTurnCount = 0
        if let wav = latestUnknownSpeakerWAV {
            try? FileManager.default.removeItem(at: wav)
            latestUnknownSpeakerWAV = nil
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

    private func reinforceIfEligible(
        speakerResponse: SpeakerIdentificationResponse,
        wavURL: URL
    ) {
        guard let similarity = speakerResponse.similarity,
            let profileID = speakerResponse.profileID,
            let durationSeconds = speakerResponse.durationSeconds,
            similarity >= Config.speakerReinforceThreshold,
            durationSeconds >= Config.speakerReinforceMinimumDurationSeconds
        else {
            return
        }

        let reinforceCopy = wavURL.deletingLastPathComponent()
            .appendingPathComponent("reinforce-\(UUID().uuidString).wav")
        try? FileManager.default.copyItem(at: wavURL, to: reinforceCopy)

        Task { [speakerClient] in
            defer { try? FileManager.default.removeItem(at: reinforceCopy) }
            do {
                let result = try await speakerClient.reinforce(
                    profileID: profileID, wavURL: reinforceCopy
                )
                if result.accepted {
                    print(
                        "[speaker] reinforced profile \(profileID) "
                            + "(similarity=\(similarity), duration=\(durationSeconds)s)"
                    )
                }
            } catch {
                print("[speaker] reinforcement failed: \(error.localizedDescription)")
            }
        }
    }
}
