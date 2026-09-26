import Foundation
import Testing
@testable import FanCurve

@Suite("Calculator")
struct CalculatorTests {
    @Test(arguments: [("23*1.21", 27.83), ("2+3*4", 14), ("(2+3)*4", 20), ("2^10", 1024), ("10 % 3", 1), ("-4+1", -3), ("7÷2", 3.5), ("1,5*2", 3)])
    func evaluates(_ input: String, _ expected: Double) throws {
        let v = try #require(Calculator.evaluate(input))
        #expect(abs(v - expected) < 1e-9)
    }

    @Test(arguments: ["hello", "12", "2+", "(1+2", "1/0", "rm -rf", ""])
    func rejects(_ input: String) {
        #expect(Calculator.evaluate(input) == nil)
    }

    @Test func formats() {
        #expect(Calculator.format(4) == "4")
        #expect(Calculator.format(27.83) == "27.83")
    }
}

@Suite("Quick-add events")
struct EventParserTests {
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 10))!

    @Test func timedEventWithDuration() throws {
        let e = try #require(EventParser.parse("event lunch with Sam tomorrow at 1pm for 45 min", now: now))
        #expect(e.title == "Lunch with Sam")
        #expect(!e.allDay)
        #expect(Calendar.current.component(.hour, from: e.start) == 13)
        #expect(e.end.timeIntervalSince(e.start) == 45 * 60)
    }

    @Test func defaultsToOneHour() throws {
        let e = try #require(EventParser.parse("event dentist friday 10:30", now: now))
        #expect(e.title == "Dentist")
        #expect(e.end.timeIntervalSince(e.start) == 3600)
    }

    @Test func dateWithoutTimeIsAllDay() throws {
        let e = try #require(EventParser.parse("event review on 3 october", now: now))
        #expect(e.allDay)
        #expect(e.title == "Review")
        #expect(Calendar.current.component(.hour, from: e.start) == 0)
    }

    @Test func noDateMeansNoEvent() {
        #expect(EventParser.parse("event buy milk", now: now) == nil)
    }

    @Test func freeSlotsSkipMeetings() {
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        let busy = [(start: at(10), end: at(11)), (start: at(11), end: at(12, 30)), (start: at(16, 45), end: at(18))]
        let free = EventParser.freeSlots(busy: busy, day: day, startHour: 9, endHour: 17, now: at(8))
        #expect(free.map(\.start) == [at(9), at(12, 30)])
        #expect(free.map(\.end) == [at(10), at(16, 45)])
    }

    @Test func freeSlotsStartFromNowToday() {
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        let now = cal.date(bySettingHour: 14, minute: 10, second: 0, of: day)!
        let free = EventParser.freeSlots(busy: [], day: day, startHour: 9, endHour: 17, now: now)
        #expect(free.first?.start == cal.date(bySettingHour: 14, minute: 30, second: 0, of: day))
    }
}

@Suite("Autocomplete text")
@MainActor
struct AutocompleteTextTests {
    @Test func editDistance() {
        #expect(Autocomplete.editDistance("adress", "address") == 1)
        #expect(Autocomplete.editDistance("kitten", "sitting") == 3)
        #expect(Autocomplete.editDistance("", "abc") == 3)
    }

    @Test func tidyDropsLeadingSpaceAfterSpace() {
        #expect(Autocomplete.tidy(" there", after: "hello ") == "there")
        #expect(Autocomplete.tidy(" there", after: "hello") == " there")
        #expect(Autocomplete.tidy("a", after: "x ") == nil)
        #expect(Autocomplete.tidy("one\ntwo", after: "x ") == "one two")
    }

    @Test func extractsNamesAndTerms() {
        let terms = Autocomplete.extractTerms(from: "Hi Thijs, the FanCurve build for the M5 is ready. Then talk to Spike Reply on Monday.")
        #expect(terms.contains("Thijs"))
        #expect(terms.contains("FanCurve"))
        #expect(terms.contains("M5"))
        #expect(terms.contains("Spike Reply"))
        #expect(!terms.contains("Monday"))
        #expect(!terms.contains("Hi"))
    }

    @Test func ignoresVersionNumbers() {
        #expect(!Autocomplete.extractTerms(from: "Released as v2026 today").contains("v2026"))
    }
}

@Suite("Quicklinks and windows")
@MainActor
struct PaletteToolTests {
    @Test func quicklinkEncodesQuery() {
        let l = Quicklink(name: "GitHub", keyword: "gh", url: "https://github.com/search?q={query}")
        #expect(l.resolved("fan curve & more")?.absoluteString == "https://github.com/search?q=fan%20curve%20%26%20more")
        #expect(l.takesQuery)
    }

    @Test func quicklinkAddsScheme() {
        let l = Quicklink(name: "Site", keyword: "", url: "example.com")
        #expect(l.resolved("")?.absoluteString == "https://example.com")
        #expect(!l.takesQuery)
    }

    @Test func quicklinkKeywordHitComesFirst() {
        let q = Quicklinks()
        q.links = [Quicklink(name: "GitHub", keyword: "gh", url: "https://github.com/search?q={query}")]
        let items = q.items(for: "gh fancurve")
        #expect(items.first?.title == "GitHub: fancurve")
    }

    @Test func windowTargets() {
        let screen = CGRect(x: 0, y: 25, width: 1200, height: 800)
        let current = CGRect(x: 100, y: 100, width: 400, height: 300)
        func t(_ id: String) -> CGRect? { WindowSnap.actions.first { $0.id == id }.map { WindowSnap.target($0, in: screen, current: current) } }
        let left = t("left"), q4 = t("q4"), third = t("third2"), centre = t("centre")
        #expect(left == CGRect(x: 0, y: 25, width: 600, height: 800))
        #expect(q4 == CGRect(x: 600, y: 425, width: 600, height: 400))
        #expect(third == CGRect(x: 400, y: 25, width: 400, height: 800))
        #expect(centre == CGRect(x: 400, y: 275, width: 400, height: 300))
    }
}
