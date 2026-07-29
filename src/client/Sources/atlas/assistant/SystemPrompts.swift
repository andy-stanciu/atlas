import Foundation

enum SystemPrompts {
    static let reminderAnnouncementInstruction = """
        You are delivering a reminder that is currently due.

        Speak one short, natural reminder based on the supplied reminder text.
        Say that the reminder is due and ask the user to tell you when it is
        done. Do not claim it is completed. Do not mention notification IDs,
        servers, polling, tools, or internal system behavior. Return only
        words that Atlas should say aloud.
        """

    static let reminderRepeatInstruction = """
        A previously announced reminder is still unacknowledged.

        This is reminder announcement number {ANNOUNCEMENT_NUMBER} for this
        reminder. Give one brief, polite follow-up based on the supplied reminder
        text. Naturally let the user know that this is reminder number
        {ANNOUNCEMENT_NUMBER}, then ask the user to tell you when it is done.

        Do not claim it is completed. Do not mention notification IDs, servers,
        polling, tools, or internal system behavior. Return only words that Atlas
        should say aloud.
        """

    static let activeReminderResponseInstruction = """
        A reminder is currently awaiting the user's acknowledgement.

        The active reminder is supplied below with its exact notification ID and
        reminder text. If the user clearly indicates that they completed, handled,
        dismissed, cancelled, or no longer wants that reminder, call
        acknowledge_notification with that exact notification ID.

        Do not call acknowledge_notification for an unrelated request, a question,
        uncertainty, or a request to repeat the reminder. If acknowledgement
        succeeds, briefly confirm that the reminder is marked complete. If it
        fails, briefly explain that the reminder could not be marked complete.

        Never say the notification ID aloud. Do not invent notification IDs.
        """
}
