import Foundation
import ServiceLifecycle

/// Removes expired sessions on a timer.
///
/// Ticket 04: the background work is small — no job queue, no cron, no external
/// scheduler, just periodic tasks under ServiceLifecycle, which Hummingbird makes
/// the default idiom rather than something bolted on.
///
/// Housekeeping rather than enforcement: expiry is checked on every request, so a
/// session that lapses between sweeps is already refused. This only stops the table
/// growing forever.
struct SessionReaper: Service {
    let sessions: SessionRepository
    let interval: Duration

    init(sessions: SessionRepository, interval: Duration = .seconds(3600)) {
        self.sessions = sessions
        self.interval = interval
    }

    func run() async throws {
        // `cancelOnGracefulShutdown` is what makes a sweep stop promptly on shutdown
        // rather than holding the process open for up to an hour.
        try await cancelOnGracefulShutdown {
            while true {
                try await Task.sleep(for: interval)
                _ = try? sessions.reapExpired(before: Date())
            }
        }
    }
}
