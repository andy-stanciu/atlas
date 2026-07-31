import Foundation

actor NotificationCoordinator {
    typealias DeliveryContext = @Sendable () async -> Bool?
    typealias AnnouncementStarted = @Sendable () async -> Void

    typealias Deliver =
        @Sendable (
            PendingNotification,
            Int,
            Bool,
            @escaping AnnouncementStarted
        ) async throws -> Bool

    private let toolServer: ToolServerClient
    private let deliveryContext: DeliveryContext
    private let deliver: Deliver
    private let pollInterval: TimeInterval
    private let repeatInterval: TimeInterval

    private var activeReminder: ActiveReminder?
    private var oneShotDeliveryInFlight = false
    private var pollingTask: Task<Void, Never>?

    init(
        toolServer: ToolServerClient,
        pollInterval: TimeInterval,
        repeatInterval: TimeInterval,
        deliveryContext: @escaping DeliveryContext,
        deliver: @escaping Deliver
    ) {
        self.toolServer = toolServer
        self.pollInterval = pollInterval
        self.repeatInterval = repeatInterval
        self.deliveryContext = deliveryContext
        self.deliver = deliver
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

    func acknowledgementEligibleReminderSnapshot() -> PendingNotification? {
        guard let reminder = activeReminder else {
            return nil
        }

        guard reminder.notification.kind == .reminder else {
            return nil
        }

        return reminder.notification
    }

    func markAnnouncementStarted(notificationID: String) {
        guard
            let reminder = activeReminder,
            reminder.notification.id == notificationID,
            reminder.notification.kind == .reminder
        else {
            return
        }
    }

    func markAcknowledged(notificationID: String) {
        guard
            let reminder = activeReminder,
            reminder.notification.id == notificationID,
            reminder.notification.kind == .reminder
        else {
            return
        }
        activeReminder = nil
    }

    func isActive(notificationID: String) -> Bool {
        activeReminder?.notification.id == notificationID
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await acquireNotificationIfNeeded()
                await deliverReminderIfDue()
            } catch is CancellationError {
                return
            } catch {
                print(
                    "[notifications] polling error: "
                        + error.localizedDescription
                )
            }

            do {
                try await Task.sleep(for: .seconds(pollInterval))
            } catch {
                return
            }
        }
    }

    private func acquireNotificationIfNeeded() async throws {
        guard activeReminder == nil else {
            return
        }

        guard !oneShotDeliveryInFlight else {
            return
        }

        guard let notification = try await toolServer.nextNotification()
        else {
            return
        }

        switch notification.kind {
        case .reminder:
            activeReminder = ActiveReminder(
                notification: notification,
                announcementCount: 0,
                nextAnnouncementAt: .now,
                isAnnouncementInFlight: false
            )

        case .confirmation:
            await deliverOneShot(notification)
        }
    }

    private func deliverOneShot(
        _ notification: PendingNotification
    ) async {
        guard notification.kind == .confirmation else {
            return
        }
        guard !oneShotDeliveryInFlight else {
            return
        }

        guard let wasConversationActive = await deliveryContext() else {
            return
        }

        oneShotDeliveryInFlight = true

        defer {
            oneShotDeliveryInFlight = false
        }

        do {
            let completed = try await deliver(
                notification,
                1,
                wasConversationActive,
                {}
            )

            guard completed else {
                return
            }

            try await toolServer.markNotificationDelivered(
                notificationID: notification.id
            )
        } catch {
            print(
                "[notifications] one-shot delivery failed for "
                    + "\(notification.id): "
                    + error.localizedDescription
            )
        }
    }

    private func deliverReminderIfDue() async {
        guard var reminder = activeReminder else {
            return
        }

        guard reminder.notification.kind == .reminder else {
            activeReminder = nil
            return
        }

        guard !reminder.isAnnouncementInFlight else {
            return
        }

        guard reminder.nextAnnouncementAt <= .now else {
            return
        }

        guard let wasConversationActive = await deliveryContext() else {
            return
        }

        reminder.isAnnouncementInFlight = true
        activeReminder = reminder

        do {
            let announcementNumber = reminder.announcementCount + 1
            let notificationID = reminder.notification.id

            let completed = try await deliver(
                reminder.notification,
                announcementNumber,
                wasConversationActive,
                { [weak self] in
                    await self?.markAnnouncementStarted(
                        notificationID: notificationID
                    )
                }
            )

            finishReminderDelivery(
                notificationID: notificationID,
                completed: completed
            )
        } catch {
            print(
                "[notifications] reminder delivery failed for "
                    + "\(reminder.notification.id): "
                    + error.localizedDescription
            )

            finishReminderDelivery(
                notificationID: reminder.notification.id,
                completed: false
            )
        }
    }

    private func finishReminderDelivery(
        notificationID: String,
        completed: Bool
    ) {
        guard var reminder = activeReminder else {
            return
        }

        guard reminder.notification.id == notificationID else {
            return
        }

        reminder.isAnnouncementInFlight = false

        if completed {
            reminder.announcementCount += 1

            reminder.nextAnnouncementAt = Date()
                .addingTimeInterval(repeatInterval)
        } else {
            reminder.nextAnnouncementAt = Date()
                .addingTimeInterval(pollInterval)
        }

        activeReminder = reminder
    }
}
