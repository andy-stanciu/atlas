import Foundation

actor NotificationCoordinator {
    typealias DeliveryContext = @Sendable () async -> Bool?
    typealias ReminderStarted = @Sendable () async -> Void

    typealias Deliver =
        @Sendable (
            PendingNotification,
            Int,
            Bool,
            @escaping ReminderStarted
        ) async throws -> Bool

    private let toolServer: ToolServerClient
    private let deliveryContext: DeliveryContext
    private let deliver: Deliver
    private let pollInterval: TimeInterval
    private let repeatInterval: TimeInterval

    private var activeReminder: ActiveReminder?
    private var acknowledgementEligibleNotificationID: String?
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
        guard
            let reminder = activeReminder,
            acknowledgementEligibleNotificationID == reminder.notification.id
        else {
            return nil
        }

        return reminder.notification
    }

    func markAnnouncementStarted(notificationID: String) {
        guard activeReminder?.notification.id == notificationID else {
            return
        }

        acknowledgementEligibleNotificationID = notificationID
    }

    func markAcknowledged(notificationID: String) {
        guard activeReminder?.notification.id == notificationID else {
            return
        }

        acknowledgementEligibleNotificationID = nil
        activeReminder = nil
    }

    func isActive(notificationID: String) -> Bool {
        activeReminder?.notification.id == notificationID
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await acquireReminderIfNeeded()
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

    private func acquireReminderIfNeeded() async throws {
        guard activeReminder == nil else {
            return
        }

        guard let notification = try await toolServer.nextNotification()
        else {
            return
        }
        acknowledgementEligibleNotificationID = nil
        activeReminder = ActiveReminder(
            notification: notification,
            announcementCount: 0,
            nextAnnouncementAt: .now,
            isAnnouncementInFlight: false
        )
    }

    private func deliverReminderIfDue() async {
        guard var reminder = activeReminder else {
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

            finishDelivery(
                notificationID: reminder.notification.id,
                completed: completed
            )
        } catch {
            print(
                "[notifications] delivery failed for "
                    + "\(reminder.notification.id): "
                    + error.localizedDescription
            )

            finishDelivery(
                notificationID: reminder.notification.id,
                completed: false
            )
        }
    }

    private func finishDelivery(
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
