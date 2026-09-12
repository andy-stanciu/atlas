import Foundation

enum Log {
    private static let colorsEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["ATLAS_LOG_COLOR"] {
            return override != "0"
        }

        return isatty(fileno(stdout)) == 1 && environment["TERM"] != nil
    }()

    private enum Palette {
        static let white = "\u{001B}[38;5;255m"
        static let grey = "\u{001B}[38;5;243m"
        static let purple = "\u{001B}[38;5;146m"
        static let green = "\u{001B}[38;5;108m"
        static let red = "\u{001B}[38;5;174m"
        static let cyan = "\u{001B}[38;5;80m"
        static let reset = "\u{001B}[0m"
    }

    private static var lineIsOpen = false

    private static func write(
        _ text: String,
        color: String,
        terminator: String = "\n"
    ) {
        if lineIsOpen, terminator != "" {
            Swift.print("")
            appendToTranscript("\n")
            lineIsOpen = false
        }

        if colorsEnabled {
            Swift.print(color + text + Palette.reset, terminator: terminator)
        } else {
            Swift.print(text, terminator: terminator)
        }
        appendToTranscript(text + terminator)

        lineIsOpen = terminator.isEmpty
        fflush(stdout)
    }

    private static func appendToTranscript(_ text: String) {
        guard Config.persistentLogMode else { return }
        PersistentLog.appendTranscript(text)
    }

    static func blank() {
        if lineIsOpen {
            Swift.print("")
            appendToTranscript("\n")
            lineIsOpen = false
        }
        Swift.print("")
        appendToTranscript("\n")
        fflush(stdout)
    }

    static func transcript(_ message: String, terminator: String = "\n") {
        write(message, color: Palette.white, terminator: terminator)
    }

    static func timing(_ message: String) {
        if Config.printTimingDebug {
            write("[timing] \(message)", color: Palette.grey)
        }
    }

    static func speaker(_ message: String) {
        if Config.printSpeakerDebug {
            write("[speaker] \(message)", color: Palette.purple)
        }
    }

    static func toolLoop(_ message: String) {
        if Config.printToolCallDebug {
            write("[tool loop] \(message)", color: Palette.green)
        }
    }

    static func toolResult(_ name: String, _ message: String) {
        if Config.printToolCallDebug {
            write("[tool result] \(name): \(message)", color: Palette.green)
        }
    }

    static func postprocess(_ message: String) {
        write("[postprocess] \(message)", color: Palette.red)
    }

    static func endpoint(_ message: String) {
        if Config.printEndpointDebug {
            write("[endpoint] \(message)", color: Palette.cyan)
        }
    }

    static func system(_ message: String, terminator: String = "\n") {
        write(message, color: Palette.grey, terminator: terminator)
    }

    static var isInteractiveTerminal: Bool {
        colorsEnabled
    }

    static func control(_ sequence: String) {
        Swift.print(sequence, terminator: "")
        lineIsOpen = false
        fflush(stdout)
    }
}
