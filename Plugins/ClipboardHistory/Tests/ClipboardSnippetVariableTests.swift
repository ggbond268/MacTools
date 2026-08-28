import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardSnippetVariableTests: XCTestCase {
    func testExpandedLimitCountsUTF8LiteralsTransformationsAndNotCursorMarker() throws {
        var context = context("é")
        context.maximumUTF8ByteCount = 4
        XCTAssertEqual(try ClipboardSnippetTemplateEngine.expand("{{clipboard}}{{cursor}}{{clipboard}}", context: context).text, "éé")
        for template in ["x{{clipboard}}{{clipboard}}", "{{clipboard}}{{clipboard}}x", "ééé", #"{{clipboard fallback="12345"}}"#] {
            if template.contains("fallback") { context.clipboardText = nil }
            XCTAssertThrowsError(try ClipboardSnippetTemplateEngine.expand(template, context: context)) {
                XCTAssertEqual($0 as? ClipboardSnippetTemplateError, .expandedTextTooLarge(maximumByteCount: 4))
            }
        }
        context.clipboardText = "ßßß"
        XCTAssertThrowsError(try ClipboardSnippetTemplateEngine.expand(#"{{clipboard case="upper"}}"#, context: context))
    }

    func testRepeatedClipboardExpansionRejectsOversizedOutputWithoutReturningPartialText() async throws {
        var context = context(String(repeating: "a", count: 1_024 * 1_024))
        context.maximumUTF8ByteCount = 1_024 * 1_024
        do {
            _ = try await ClipboardSnippetTemplateEngine.expandAsync(String(repeating: "{{clipboard}}", count: 100), context: context)
            XCTFail("Expected explicit output limit")
        } catch {
            XCTAssertEqual(error as? ClipboardSnippetTemplateError, .expandedTextTooLarge(maximumByteCount: context.maximumUTF8ByteCount))
        }
    }

    func testExpansionCancellationDoesNotReturnAnOutput() async {
        let context = context("x")
        let task = Task {
            try await ClipboardSnippetTemplateEngine.expandAsync(String(repeating: "{{clipboard}}", count: 100_000), context: context)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testAsyncExpansionEvaluatesVariablesOffTheMainThread() async throws {
        var context = context()
        context.uuid = {
            XCTAssertFalse(Thread.isMainThread)
            return UUID()
        }
        let expanded = try await ClipboardSnippetTemplateEngine.expandAsync("{{uuid}}", context: context)
        XCTAssertNotNil(UUID(uuidString: expanded.text))
    }

    func testCursorPreviewIncludesClipboardVariablesFromTheDraft() throws {
        let options = ClipboardSnippetVariableOptions(variable: .cursor)
        let draft = "Hi {{clipboard}}, "
        let selection = NSRange(location: draft.utf16.count, length: 0)
        let template = options.previewTemplate(text: draft, selection: selection)
        XCTAssertTrue(ClipboardSnippetTemplateEngine.requiresClipboardText(template))
        let preview = try options.preview(context: context("NAME"), text: draft, selection: selection)
        XCTAssertEqual(preview.text, "Hi NAME, ")
        XCTAssertEqual(preview.cursorOffsetFromEnd, 0)
        XCTAssertFalse(ClipboardSnippetTemplateEngine.requiresClipboardText(#"\{{clipboard}} {{cursor}}"#))
        XCTAssertFalse(ClipboardSnippetTemplateEngine.requiresClipboardText("{{date}}"))
    }

    private func context(_ text: String? = nil, date: String = "2024-01-02T03:04:05Z") -> ClipboardSnippetExpansionContext {
        ClipboardSnippetExpansionContext(
            date: ISO8601DateFormatter().date(from: date)!,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(identifier: "UTC")!,
            clipboardText: text,
            uuid: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
        )
    }

    private func expand(_ template: String, text: String? = nil, date: String = "2024-01-02T03:04:05Z") throws -> String {
        try ClipboardSnippetTemplateEngine.expand(template, context: context(text, date: date)).text
    }

    func testDateOptionsCanBeCombinedInAnyOrder() throws {
        XCTAssertEqual(try expand(#"{{datetime timezone="America/New_York" offset="+1d" format="yyyy-MM-dd HH:mm"}}"#), "2024-01-02 22:04")
        XCTAssertEqual(try expand(#"{{time format="HH:mm:ss" offset="-5m"}}"#), "02:59:05")
        XCTAssertEqual(try expand(#"{{date offset="+1M" format="yyyy-MM-dd"}}"#), "2024-02-02")
        XCTAssertEqual(try expand(#"{{date offset="-1w" format="yyyy-MM-dd"}}"#), "2023-12-26")
        XCTAssertEqual(try expand(#"{{date offset="+1y" format="yyyy-MM-dd"}}"#), "2025-01-02")
    }

    func testCalendarDaysRespectSpringAndFallDaylightSaving() throws {
        let template = #"{{datetime format="yyyy-MM-dd HH:mm XXX" offset="+1d" timezone="America/New_York"}}"#
        XCTAssertEqual(try expand(template, date: "2024-03-09T17:00:00Z"), "2024-03-10 12:00 -04:00")
        XCTAssertEqual(try expand(template, date: "2024-11-02T16:00:00Z"), "2024-11-03 12:00 -05:00")
        XCTAssertEqual(try expand(#"{{date offset="+1M" format="yyyy-MM-dd"}}"#, date: "2024-01-31T12:00:00Z"), "2024-02-29")
    }

    func testClipboardTrimsThenFallsBackThenChangesCase() throws {
        let template = #"{{clipboard trim="true" case="upper" fallback="friend"}}"#
        XCTAssertEqual(try expand(template, text: "  Alice\n"), "ALICE")
        XCTAssertEqual(try expand(template, text: " \n"), "FRIEND")
        XCTAssertEqual(try expand(template), "FRIEND")
        XCTAssertEqual(try expand(#"{{clipboard case="lower"}}"#, text: " HELLO "), " hello ")
        XCTAssertEqual(try expand(#"{{clipboard trim="false" fallback="empty"}}"#, text: " "), " ")
    }

    func testClipboardAndFallbackAreLiteralNotRecursiveOrUnescaped() throws {
        let text = #"{{cursor}} \{{date}} {{network}}"#
        XCTAssertEqual(try expand("{{clipboard}} / {{clipboard}}", text: text), "\(text) / \(text)")
        var options = ClipboardSnippetVariableOptions(variable: .clipboard)
        options.fallback = "He said \"hello\".\n\\{{cursor}} {{date}}"
        XCTAssertEqual(try expand(options.template), options.fallback)
        XCTAssertEqual(try expand(#"\{{date}} {{date format="yyyy"}}"#), "{{date}} 2024")
    }

    func testInvalidOptionsFailRatherThanBeingSilentlyIgnored() {
        for template in [
            #"{{date unexpected="value"}}"#, #"{{date offset="tomorrow"}}"#,
            #"{{date timezone="not/a/zone"}}"#, #"{{time offset="999999999999999999999d"}}"#,
            #"{{date format="yyyy" format="MM"}}"#, #"{{clipboard trim="yes"}}"#,
            #"{{clipboard case="title"}}"#, #"{{uuid case="lower"}}"#, #"{{cursor offset="+1d"}}"#,
            #"{{clipboard fallback="\q"}}"#
        ] {
            XCTAssertThrowsError(try expand(template), template) {
                XCTAssertEqual($0 as? ClipboardSnippetTemplateError, .invalidVariableOptions, template)
            }
        }
        for template in [#"{{date format=""}}"#, #"{{date format="yyyy 'unfinished"}}"#] {
            XCTAssertThrowsError(try expand(template)) {
                XCTAssertEqual($0 as? ClipboardSnippetTemplateError, .invalidDateFormat)
            }
        }
    }

    func testEveryVariableAndPresetHasRuntimeEquivalentPreview() throws {
        for variable in ClipboardSnippetVariable.allCases {
            for format in [""] + variable.formats {
                var options = ClipboardSnippetVariableOptions(variable: variable)
                options.format = format
                let preview = try options.preview(context: context("Alice"), text: "", selection: NSRange(location: 0, length: 0))
                XCTAssertEqual(preview, try ClipboardSnippetTemplateEngine.expand(options.template, context: context("Alice")))
                XCTAssertTrue(ClipboardSnippetTemplateEngine.containsDynamicContent(options.template))
            }
        }
        XCTAssertFalse(ClipboardSnippetTemplateEngine.containsDynamicContent(#"\{{date}}"#))
    }

    func testCursorPreviewUsesInsertionLocationAndRejectsSecondMarker() throws {
        let options = ClipboardSnippetVariableOptions(variable: .cursor)
        let preview = try options.preview(context: context(), text: "Hi 🙂there!", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(preview.text, "Hi 🙂there!")
        XCTAssertEqual(preview.cursorOffsetFromEnd, 6)
        XCTAssertThrowsError(try options.preview(context: context(), text: "{{cursor}}x", selection: NSRange(location: 11, length: 0))) {
            XCTAssertEqual($0 as? ClipboardSnippetTemplateError, .multipleCursorMarkers)
        }
        // Replacing the existing marker is allowed; escaped markers are not active markers.
        XCTAssertNoThrow(try options.preview(context: context(), text: "{{cursor}}x", selection: NSRange(location: 0, length: 10)))
        XCTAssertNoThrow(try options.preview(context: context(), text: #"\{{cursor}}"#, selection: NSRange(location: 11, length: 0)))
    }

    func testOptionsDoNotLeakAcrossVariableKinds() throws {
        var options = ClipboardSnippetVariableOptions(variable: .date)
        options.format = "yyyy-MM-dd"
        options.offset = "+1d"
        options.trimsClipboard = true
        XCTAssertEqual(options.template, #"{{date format="yyyy-MM-dd" offset="+1d"}}"#)
        options.variable = .clipboard
        XCTAssertEqual(options.template, #"{{clipboard trim="true"}}"#)
        options.variable = .uuid
        XCTAssertEqual(options.template, "{{uuid}}")
    }
}
