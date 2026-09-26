extension RegressionCase {
    static let musicCases: [RegressionCase] = [
        .init(
            name: "Play a specific track",
            prompt: "Play Back in Black by AC/DC.",
            requiredTools: ["music_play"],
            expectedArgumentContains: ["music_play": ["query": "Back in Black"]],
            minimumCallCount: 1
        ),

        .init(
            name: "Play a playlist",
            kind: .edgeCase,
            prompt: "Play my chill playlist.",
            requiredTools: ["music_play"],
            expectedArgumentContains: ["music_play": ["query": "chill"]],
            minimumCallCount: 1
        ),

        .init(
            name: "Pause music",
            prompt: "Pause the music.",
            requiredTools: ["music_pause"],
            forbiddenTools: ["music_play", "music_resume"],
            minimumCallCount: 1
        ),

        .init(
            name: "Resume music",
            prompt: "Resume the music please.",
            requiredTools: ["music_resume"],
            forbiddenTools: ["music_play", "music_pause"],
            minimumCallCount: 1
        ),

        .init(
            name: "Skip to next song",
            prompt: "Skip this song.",
            requiredTools: ["music_skip"],
            forbiddenTools: ["music_previous"],
            minimumCallCount: 1
        ),

        .init(
            name: "Next song wording maps to skip",
            kind: .edgeCase,
            prompt: "Next song please.",
            requiredTools: ["music_skip"],
            forbiddenTools: ["music_previous"],
            minimumCallCount: 1
        ),

        .init(
            name: "Go to previous song",
            prompt: "Go back to the previous song.",
            requiredTools: ["music_previous"],
            forbiddenTools: ["music_skip"],
            minimumCallCount: 1
        ),

        .init(
            name: "Set music volume",
            prompt: "Set the volume to 40 percent.",
            requiredTools: ["music_volume"],
            expectedArgumentValues: ["music_volume": ["percent": .number(40)]],
            minimumCallCount: 1
        ),

        .init(
            name: "Ask what song is playing",
            prompt: "What song is playing right now?",
            requiredTools: ["music_status"],
            forbiddenTools: ["music_play"],
            minimumCallCount: 1
        ),
    ]
}
