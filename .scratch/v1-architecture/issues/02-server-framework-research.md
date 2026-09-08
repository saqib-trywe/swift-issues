# Server framework landscape research

Type: research
Status: resolved

## Question

Survey the current (as of the latest released Swift version) landscape of Swift server frameworks suitable for an HTTP API server built around structured concurrency (async/await, actors): **Vapor**, **Hummingbird**, and bare **SwiftNIO**. For each, capture:

- Current maturity/maintenance status and community activity
- How idiomatically it supports async/await and actor-isolated request handling
- WebSocket/SSE support (relevant to later real-time work, even though v1 is pull-based)
- Linux deployment story (this system is meant to be self-hostable, likely on Linux)
- Notable limitations or rough edges

Do not decide — this feeds the follow-on ticket [Choose server framework & concurrency model](../issues/04-choose-server-framework-concurrency-model.md).
