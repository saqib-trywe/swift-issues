import Core
import Foundation
import Testing

@Suite("Priority")
struct PriorityTests {

    @Test(
        "known cases round trip through their wire value",
        arguments: [
            (Priority.none, "none"),
            (Priority.low, "low"),
            (Priority.medium, "medium"),
            (Priority.high, "high"),
            (Priority.urgent, "urgent"),
        ]
    )
    func knownCasesRoundTrip(priority: Priority, wire: String) {
        #expect(priority.wireValue == wire)
        #expect(Priority(wireValue: wire) == priority)
    }

    @Test("an unrecognised wire value is preserved verbatim, not coerced")
    func unrecognisedValueIsPreservedVerbatim() {
        let priority = Priority(wireValue: "blocker")

        #expect(priority == .unknown("blocker"))
        #expect(priority.wireValue == "blocker")
    }

    @Test("known priorities order from none up to urgent")
    func knownPrioritiesOrderAscending() {
        let shuffled: [Priority] = [.urgent, .none, .high, .low, .medium]

        #expect(shuffled.sorted() == [.none, .low, .medium, .high, .urgent])
    }

    /// An unrecognised priority has no defensible position among the known ones,
    /// so it sorts after all of them rather than silently ranking as some
    /// severity it is not.
    @Test("unknown priorities sort after every known one")
    func unknownPrioritiesSortLast() {
        let shuffled: [Priority] = [.unknown("blocker"), .urgent, .none]

        #expect(shuffled.sorted() == [.none, .urgent, .unknown("blocker")])
    }

    @Test("two unknown priorities order by wire value, so sorting stays deterministic")
    func unknownPrioritiesOrderDeterministically() {
        let shuffled: [Priority] = [.unknown("zeta"), .unknown("alpha")]

        #expect(shuffled.sorted() == [.unknown("alpha"), .unknown("zeta")])
    }
}
