import ClientStore
import Core
import Foundation
import TestSupport
import Testing

@testable import AppCore

/// A due date is a calendar day, not an instant. Through an ordinary formatter it
/// shifts, and a task due on the first shows as overdue to a reader further west.
@Suite("Calendar date formatting")
struct CalendarDateFormatTests {

    private let format = CalendarDateFormat(locale: Locale(identifier: "en_GB"))

    @Test("a date renders as its own calendar day")
    func dateRendersAsItsOwnCalendarDay() throws {
        let date = try #require(CivilDate(wireValue: "2026-12-25"))
        #expect(format.string(for: date) == "25 December 2026")
    }

    /// The test that would catch a timezone-converting formatter: 1 January is the
    /// day a shift is most visible on, because the wrong answer changes the year.
    @Test("the first of January does not become the previous year")
    func firstOfJanuaryDoesNotShift() throws {
        let date = try #require(CivilDate(wireValue: "2026-01-01"))
        let rendered = format.string(for: date)

        #expect(rendered.contains("2026"))
        #expect(!rendered.contains("2025"))
        #expect(rendered.contains("1 January"))
    }

    /// And the last day of the year, for the shift in the other direction.
    @Test("the last of December does not become the next year")
    func lastOfDecemberDoesNotShift() throws {
        let date = try #require(CivilDate(wireValue: "2026-12-31"))
        let rendered = format.string(for: date)

        #expect(rendered.contains("2026"))
        #expect(!rendered.contains("2027"))
    }

    /// A date on a daylight-saving boundary is where a midnight anchor would break;
    /// the components are anchored at midday for this reason.
    @Test(
        "a daylight-saving boundary does not move the day",
        arguments: [
            "2026-03-29", "2026-10-25", "2026-03-08", "2026-11-01",
        ])
    func daylightSavingBoundaryDoesNotMoveTheDay(_ wire: String) throws {
        let date = try #require(CivilDate(wireValue: wire))
        let expectedDay = String(wire.suffix(2)).replacingOccurrences(
            of: "^0", with: "", options: .regularExpression)

        #expect(format.short(for: date).contains(expectedDay))
    }

    @Test("a leap day renders")
    func leapDayRenders() throws {
        let date = try #require(CivilDate(wireValue: "2028-02-29"))
        #expect(format.string(for: date).contains("29 February"))
    }

    /// The short form has to fit a table column while staying unambiguous, so the
    /// month is never a bare number.
    @Test("the short form names the month")
    func shortFormNamesTheMonth() throws {
        let date = try #require(CivilDate(wireValue: "2026-12-25"))
        let short = format.short(for: date)

        #expect(short.contains("Dec"))
        #expect(short.count < format.string(for: date).count)
    }
}

/// Ticket 10 treats these as load-bearing rather than decorative: if a surface is
/// absent, a sync guarantee is void. The copy is therefore part of the contract.
@Suite("Sync surfaces")
struct SyncSurfaceTests {

    private func status(
        attention: Int = 0,
        lost: Int = 0,
        stale: Int = 0,
        authentication: AuthenticationState = .valid,
        progress: SyncProgress = .idle
    ) -> SyncStatus {
        var status = SyncStatus()
        status.authentication = authentication
        status.progress = progress
        status.needsAttention = (0..<attention).map { _ in
            PendingOperation(
                sequence: 1,
                operation: .patchIssue(
                    opId: UUID(), id: Core.Issue.ID(), at: Date(), body: IssuePatch()),
                state: .quarantined, problem: nil, attemptCount: 1)
        }
        status.lostToDeletion = (0..<lost).map { _ in
            SupersededRecord(
                opId: UUID(),
                operation: .patchIssue(
                    opId: UUID(), id: Core.Issue.ID(), at: Date(), body: IssuePatch()),
                current: nil, reason: .deletedElsewhere, occurredAt: Date())
        }
        status.willOverwrite = (0..<stale).map { _ in
            StaleEdit(
                operation: .patchIssue(
                    opId: UUID(), id: Core.Issue.ID(), at: Date(), body: IssuePatch()),
                fields: [.title], editedAt: Date(), serverChangedAt: Date())
        }
        return status
    }

    @Test("a quiet instance shows no surfaces")
    func quietInstanceShowsNoSurfaces() {
        #expect(status().surfaces.isEmpty)
    }

    @Test("each surface appears when its condition holds")
    func eachSurfaceAppears() {
        #expect(status(attention: 1).surfaces == [.needsAttention(count: 1)])
        #expect(status(lost: 1).surfaces == [.lostToDeletion(count: 1)])
        #expect(status(stale: 1).surfaces == [.willOverwrite(count: 1)])
        #expect(
            status(authentication: .needsReauthentication).surfaces == [.needsReauthentication])
        #expect(status(progress: .rebuilding).surfaces == [.rebuilding])
        #expect(status(progress: .failed("no network")).surfaces == [.failed("no network")])
    }

    /// Something blocking must not sit below something advisory.
    @Test("surfaces are ordered most urgent first")
    func surfacesAreOrderedMostUrgentFirst() {
        let all = status(
            attention: 2, lost: 1, stale: 3, authentication: .needsReauthentication,
            progress: .rebuilding
        ).surfaces

        #expect(all.count == 5)
        #expect(all.first == .needsReauthentication)
        #expect(all.map(\.severity) == all.map(\.severity).sorted(by: >))
    }

    /// Ticket 10 is explicit: superseded means superseded-*by-deletion*. Under
    /// receipt-time last-write-wins, "someone else edited this field" describes a
    /// situation the system does not produce.
    @Test("the lost-to-deletion copy says deleted, and never blames another editor")
    func lostToDeletionCopyIsAboutDeletion() {
        let surface = SyncSurface.lostToDeletion(count: 1)

        #expect(surface.detail.lowercased().contains("deleted"))
        #expect(!surface.detail.lowercased().contains("someone else"))
        #expect(!surface.detail.lowercased().contains("conflict"))
        // The user's text is recoverable, and the copy has to say so.
        #expect(surface.detail.lowercased().contains("your text"))
    }

    /// iOS background refresh has no timing guarantee, so any freshness claim
    /// becomes a lie the moment a refresh is missed — and the user cannot tell.
    @Test("no surface implies how fresh the data is")
    func noSurfaceImpliesFreshness() {
        let everything =
            status(
                attention: 1, lost: 1, stale: 1, authentication: .needsReauthentication,
                progress: .failed("timed out")
            ).surfaces + [.rebuilding]

        for surface in everything {
            let copy = (surface.title + " " + surface.detail).lowercased()
            for phrase in ["ago", "just now", "last updated", "up to date as of"] {
                #expect(!copy.contains(phrase), "'\(phrase)' appears in \(surface)")
            }
        }
    }

    @Test("progress describes state, not freshness")
    func progressDescribesStateNotFreshness() {
        for progress in [SyncProgress.idle, .syncing, .rebuilding, .failed("x")] {
            var value = SyncStatus()
            value.progress = progress
            #expect(!value.progressDescription.lowercased().contains("ago"))
        }
    }

    /// A restore is normal recovery. Presenting it as an error tells the user
    /// something is broken when the system is doing exactly what it should.
    @Test("rebuilding is informational, not an error")
    func rebuildingIsInformational() {
        #expect(SyncSurface.rebuilding.severity == .informational)
        #expect(SyncSurface.rebuilding.detail.lowercased().contains("safe"))
    }

    /// Ticket 07: a rejected token is not a rejected write, and saying so stops
    /// people hunting for a mistake they did not make.
    @Test("re-authentication copy makes clear nothing was lost")
    func reauthenticationCopyMakesClearNothingWasLost() {
        let detail = SyncSurface.needsReauthentication.detail.lowercased()
        #expect(detail.contains("nothing has been lost"))
        #expect(SyncSurface.needsReauthentication.severity == .blocking)
    }

    /// A rejection keeps the user's text for repair, and the copy has to say that
    /// rather than implying it was discarded.
    @Test("needs-attention copy says the text is kept")
    func needsAttentionCopySaysTheTextIsKept() {
        #expect(SyncSurface.needsAttention(count: 2).detail.lowercased().contains("kept"))
    }

    /// The advisory warning has to say what will happen, or there is nothing to
    /// decide from.
    @Test("the overwrite warning says newer work will be replaced")
    func overwriteWarningSaysNewerWorkWillBeReplaced() {
        let detail = SyncSurface.willOverwrite(count: 1).detail.lowercased()
        #expect(detail.contains("newer"))
        #expect(detail.contains("replace"))
    }

    @Test("counts read correctly in the singular and the plural", arguments: [1, 2])
    func countsReadCorrectly(_ count: Int) {
        for surface in [
            SyncSurface.needsAttention(count: count),
            .lostToDeletion(count: count),
            .willOverwrite(count: count),
        ] {
            let expectedPlural = count != 1
            let title = surface.title
            #expect(title.contains("\(count)"))
            // "1 change needs" versus "2 changes need".
            #expect(title.contains("s ") == expectedPlural || title.contains("edits") == expectedPlural)
        }
    }

    @Test("progress reports how much is waiting", arguments: [0, 1, 5])
    func progressReportsHowMuchIsWaiting(_ queued: Int) {
        var status = SyncStatus()
        status.queuedCount = queued
        let description = status.progressDescription

        if queued == 0 {
            #expect(description.contains("Up to date"))
        } else {
            #expect(description.contains("\(queued)"))
            #expect(description.contains("waiting"))
        }
    }
}
