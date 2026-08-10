import Foundation

#if canImport(Darwin)
    import Darwin
#endif

final class ConsoleTranscript {
    private var activeLineCount = 1

    func showPartial(_ text: String, prefix: String = "You") {
        guard !text.isEmpty else {
            return
        }

        guard Log.isInteractiveTerminal else {
            return
        }

        let prefixed = "\(prefix): \(text)"

        erase()
        Log.transcript(prefixed, terminator: "")
        activeLineCount = lineCount(for: prefixed)
    }

    func clear() {
        erase()
        activeLineCount = 1
    }

    private func erase() {
        guard Log.isInteractiveTerminal else {
            return
        }

        if activeLineCount > 1 {
            Log.control("\u{1B}[\(activeLineCount - 1)A")
        }
        Log.control("\r\u{1B}[0J")
    }

    private func lineCount(for text: String) -> Int {
        let width = terminalWidth()
        guard width > 0 else {
            return 1
        }
        return max(1, (text.count + width - 1) / width)
    }

    private func terminalWidth() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return 80
    }
}
