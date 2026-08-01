import Foundation

actor NotificationCoordinator {
    typealias DeliveryContext = @Sendable () async -> Bool?

    typealias SpeechStarted = @Sendable () async -> Void

    typealias Deliver =
        @Sendable (
            PendingSpeech,
            Int,
            Bool,
            @escaping SpeechStarted
        ) async throws -> SpeechPlaybackOutcome

    private let toolServer: ToolServerClient
    private let deliveryContext: DeliveryContext
    private let deliver: Deliver
    private let pollInterval: TimeInterval
    private let repeatInterval: TimeInterval

    private var activeReminder: ActiveReminder?
    private var announcementDeliveryInFlight = false
    private var pollingTask: Task<Void, Never>?

    init(
        toolServer: ToolServerClient,
        pollInterval: TimeInterval,
        repeatInterval: TimeInterval,
        deliveryContext: @escaping DeliveryContext,
        deliver: @escaping Deliver
    ) {
        self.toolServer = toolServer
        self.deliveryContext = deliveryContext
        self.deliver = deliver
        self.pollInterval = pollInterval
        self.repeatInterval = repeatInterval
    }

    func start() {
        guard pollingTask == nil else {
            return
        }

        pollingTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func acknowledgementEligibleReminderSnapshot() -> PendingSpeech? {
        guard let reminder = activeReminder else {
            return nil
        }

        guard reminder.hasStartedPlayback else {
            return nil
        }

        return reminder.speech
    }

    func markReminderAcknowledged() {
        activeReminder = nil
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await acquireSpeechIfNeeded()
                await deliverReminderIfDue()
            } catch is CancellationError {
                return
            } catch {
                print(
                    "[speech] polling error: "
                        + error.localizedDescription
                )
            }

            do {
                try await Task.sleep(
                    for: .seconds(pollInterval)
                )
            } catch {
                return
            }
        }
    }

    private func acquireSpeechIfNeeded() async throws {
        guard activeReminder == nil else {
            return
        }

        guard !announcementDeliveryInFlight else {
            return
        }

        guard let speech = try await toolServer.nextSpeech() else {
            return
        }

        switch speech.kind {
        case .reminder:
            activeReminder = ActiveReminder(
                speech: speech,
                announcementCount: 0,
                nextAnnouncementAt: .now,
                isDeliveryInFlight: false,
                hasStartedPlayback: false
            )

        case .announcement:
            await deliverAnnouncement(speech)
        }
    }

    private func deliverAnnouncement(
        _ speech: PendingSpeech
    ) async {
        guard speech.kind == .announcement else {
            return
        }

        guard !announcementDeliveryInFlight else {
            return
        }

        guard let wasConversationActive = await deliveryContext() else {
            return
        }

        announcementDeliveryInFlight = true

        defer {
            announcementDeliveryInFlight = false
        }

        do {
            let outcome = try await deliver(
                speech,
                1,
                wasConversationActive,
                {}
            )

            guard outcome == .completed || outcome == .interrupted else {
                return
            }

            try await toolServer.markAnnouncementDelivered(
                speechID: speech.id
            )
        } catch {
            print(
                "[speech] announcement delivery failed for "
                    + "\(speech.id): "
                    + error.localizedDescription
            )
        }
    }

    private func deliverReminderIfDue() async {
        guard var reminder = activeReminder else {
            return
        }

        guard !reminder.isDeliveryInFlight else {
            return
        }

        guard reminder.nextAnnouncementAt <= .now else {
            return
        }

        guard let wasConversationActive = await deliveryContext() else {
            return
        }

        reminder.isDeliveryInFlight = true
        activeReminder = reminder

        let speechID = reminder.speech.id
        let announcementNumber = reminder.announcementCount + 1

        do {
            let outcome = try await deliver(
                reminder.speech,
                announcementNumber,
                wasConversationActive,
                { [weak self] in
                    await self?.markReminderPlaybackStarted(
                        speechID: speechID
                    )
                }
            )

            finishReminderDelivery(
                speechID: speechID,
                outcome: outcome
            )
        } catch {
            print(
                "[speech] reminder delivery failed for "
                    + "\(speechID): "
                    + error.localizedDescription
            )

            finishReminderDelivery(
                speechID: speechID,
                outcome: .failed
            )
        }
    }

    private func markReminderPlaybackStarted(speechID: Int) {
        guard var reminder = activeReminder else {
            return
        }

        guard reminder.speech.id == speechID else {
            return
        }

        reminder.hasStartedPlayback = true
        activeReminder = reminder
    }

    private func finishReminderDelivery(
        speechID: Int,
        outcome: SpeechPlaybackOutcome
    ) {
        guard var reminder = activeReminder else {
            return
        }

        guard reminder.speech.id == speechID else {
            return
        }

        reminder.isDeliveryInFlight = false

        switch outcome {
        case .completed, .interrupted:
            reminder.announcementCount += 1
            reminder.nextAnnouncementAt = Date()
                .addingTimeInterval(repeatInterval)

        case .notStarted, .failed:
            reminder.nextAnnouncementAt = Date()
                .addingTimeInterval(pollInterval)
        }

        activeReminder = reminder
    }
}
