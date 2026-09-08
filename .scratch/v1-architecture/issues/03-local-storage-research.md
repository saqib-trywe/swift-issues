# Client-side local storage research

Type: research
Status: resolved

## Question

Survey local/offline storage options for Swift native clients (macOS/iOS/iPadOS) that need to hold a full offline copy of tracker data plus a queue of pending offline operations: **SwiftData**, **GRDB** (SQLite), and a hand-rolled SQLite layer. For each, capture:

- Maturity on the latest released OS versions
- Concurrency/thread-safety model (how actor-friendly is it?)
- Support for the kind of queryable relational data this app needs (Projects/Issues/Comments with filters)
- How naturally it supports "pending offline operation queue" semantics (an ordered log of not-yet-synced writes)

Do not decide — this feeds the follow-on ticket [Choose client-side local storage & offline queue design](../issues/05-choose-local-storage-offline-queue.md).
