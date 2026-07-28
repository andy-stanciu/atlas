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

        Give one brief, polite follow-up based on the supplied reminder text.
        Ask the user to tell you when it is done. Do not claim it is completed.
        Do not mention notification IDs, servers, polling, tools, or internal
        system behavior. Return only words that Atlas should say aloud.
        """
}