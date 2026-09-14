import Foundation
import Server

// Deliberately thin: everything testable lives in the Server library, and this is
// the only file allowed to exit.
exit(await ServerCLI.run())
