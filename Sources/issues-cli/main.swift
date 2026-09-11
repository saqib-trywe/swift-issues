import CLI
import Foundation

// The only place the process exits. Everything above returns its code, so the
// whole of dispatch stays reachable from a test.
exit(await IssuesCLI.run())
