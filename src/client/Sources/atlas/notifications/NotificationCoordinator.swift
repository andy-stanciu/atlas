import Foundation

actor NotificationCoordinator {
    typealias IsIdle = @Sendable () async -> Bool

    typealias Deliver = @Sendable (
        PendingNotification,
        Bool
    ) async throws -> Bool

    private let toolServer: ToolServerClient
    private let isIdle: IsIdle
    private let deliver: Deliver
    private let pollInterval: TimeInterval
    private let repeatInterval: TimeInterval

    private var activeReminder: ActiveReminder?
    private var pollingTask: Task<Void, Never>?

    init(
        toolServer: ToolServerClient,
        pollInterval: TimeInterval,
        repeatInterval: TimeInterval,
        isIdle: @escaping IsIdle,
        deliver: @escaping Deliver
    ) {
        self.toolServer = toolServer
        self.pollInterval = pollInterval
        self.repeatInterval = repeatInterval
        self.isIdle = isIdle
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

    func activeReminderSnapshot() -> PendingNotification? {
        activeReminder?.notification
    }

    func markAcknowledged(notificationID: String) {
        guard activeReminder?.notification.id == notificationID else {
            return
        }

        activeReminder = nil
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

        activeReminder = ActiveReminder(
            notification: notification,
            hasBeenAnnounced: false,
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

        guard await isIdle() else {
            return
        }

        reminder.isAnnouncementInFlight = true
        activeReminder = reminder

        do {
            let completed = try await deliver(
                reminder.notification,
                reminder.hasBeenAnnounced
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
            reminder.hasBeenAnnounced = true

            reminder.nextAnnouncementAt = Date()
                .addingTimeInterval(repeatInterval)
        } else {
            reminder.nextAnnouncementAt = Date()
                .addingTimeInterval(10)
        }

        activeReminder = reminder
    }
}