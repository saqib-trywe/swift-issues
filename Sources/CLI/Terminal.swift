import Foundation

/// Somewhere text goes. The seam exists so every command's output can be
/// asserted, rather than inspected by eye.
protocol TextSink: Sendable {
    func write(_ text: String)
}

/// Writes to a file descriptor.
///
/// A descriptor rather than a `FileHandle` because this has to cross concurrency
/// domains, and an `Int32` is trivially `Sendable` where `FileHandle` is not.
struct FileDescriptorSink: TextSink {
    let descriptor: Int32

    func write(_ text: String) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            // A short write is normal on a pipe, so the loop is not defensive
            // padding: without it, piping into `head` truncates output.
            let written = bytes.withUnsafeBufferPointer { buffer in
                Foundation.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            }
            guard written > 0 else { return }
            offset += written
        }
        _ = bytes  // keeps the buffer alive across the loop
    }
}

/// The process's console, as a value.
///
/// Carries whether each stream is a terminal because three separate ticket 11
/// rules turn on it: colour only when stdout is a TTY, never prompt when stdin
/// is not, and `--yes` required for destructive commands off a TTY.
struct Terminal: Sendable {
    var output: any TextSink
    var error: any TextSink
    var isOutputTerminal: Bool
    var isInputTerminal: Bool
    /// Reads one line from stdin. A seam so prompting is testable.
    var readLine: @Sendable () -> String?
    /// Reads without echoing. Separate from `readLine` because a password must
    /// not appear on screen or in a screenshare.
    var readSecret: @Sendable () -> String?

    func print(_ text: String = "") { output.write(text + "\n") }
    func printError(_ text: String) { error.write(text + "\n") }

    /// Whether to colour output. `NO_COLOR` is honoured at any value, per the
    /// convention's own wording, and a redirected stdout is never coloured.
    func usesColour(environment: [String: String]) -> Bool {
        isOutputTerminal && environment["NO_COLOR"] == nil
    }

    static func standard() -> Terminal {
        Terminal(
            output: FileDescriptorSink(descriptor: STDOUT_FILENO),
            error: FileDescriptorSink(descriptor: STDERR_FILENO),
            isOutputTerminal: isatty(STDOUT_FILENO) == 1,
            isInputTerminal: isatty(STDIN_FILENO) == 1,
            readLine: { Swift.readLine(strippingNewline: true) },
            readSecret: Terminal.readWithoutEcho
        )
    }

    /// Turns off terminal echo around a single read.
    ///
    /// Restores the old settings on every path, including a thrown read, because
    /// leaving a shell with echo disabled looks like a hung terminal.
    private static func readWithoutEcho() -> String? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return Swift.readLine(strippingNewline: true)
        }
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet) == 0 else {
            return Swift.readLine(strippingNewline: true)
        }
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        return Swift.readLine(strippingNewline: true)
    }
}
