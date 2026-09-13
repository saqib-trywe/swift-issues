import Foundation
import MCP

// The only place the process reads stdin and writes stdout. Everything above is
// request-in/response-out, so the protocol and the tools are testable without one.
await StdioServer.run()
