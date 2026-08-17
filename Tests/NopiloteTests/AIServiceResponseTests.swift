import XCTest
@testable import Nopilote

final class AIServiceResponseTests: XCTestCase {
    func testDeepSeekV4FlashIsNotSentUnsupportedImagePayload() {
        let configuration = AIProviderConfiguration(kind: .deepSeek, model: "deepseek-v4-flash", apiKey: "test")
        XCTAssertFalse(AIService.supportsImages(configuration))
    }

    func testDeepSeekChatRemainsTextOnly() {
        let configuration = AIProviderConfiguration(kind: .deepSeek, model: "deepseek-chat", apiKey: "test")
        XCTAssertFalse(AIService.supportsImages(configuration))
    }

    func testDeepSeekV4PayloadFallsBackToTextWithImageNotice() throws {
        let configuration = AIProviderConfiguration(kind: .deepSeek, model: "deepseek-v4-flash", apiKey: "test")
        let image = NoteImage(name: "photo.png", mimeType: "image/png", base64Data: "aGVsbG8=")
        let request = try AIService.requestForTesting(configuration: configuration, context: "read the note", images: [image])
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let user = try XCTUnwrap(messages.last)
        let content = try XCTUnwrap(user["content"] as? String)
        XCTAssertEqual(content, "read the note")
        XCTAssertFalse(content.contains("aGVsbG8="))
    }

    func testTextOnlyPayloadDoesNotContainImagePart() throws {
        let configuration = AIProviderConfiguration(kind: .deepSeek, model: "deepseek-chat", apiKey: "test")
        let image = NoteImage(name: "photo.png", mimeType: "image/png", base64Data: "aGVsbG8=")
        let request = try AIService.requestForTesting(configuration: configuration, context: "read the note", images: [image])
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let user = try XCTUnwrap(messages.last)
        XCTAssertTrue(user["content"] is String)
    }

    func testTextOnlyProviderUsesOCRNoticeWhenImageContainsText() {
        let configuration = AIProviderConfiguration(kind: .deepSeek, model: "deepseek-v4-flash", apiKey: "test")
        let note = NoteSnapshot(
            id: "note", title: "title", account: "account", folder: "folder", folderID: "folder",
            html: "<p>text</p>", plainText: "text", modificationDate: nil,
            modificationToken: "token", isLocked: false, isShared: false,
            images: [NoteImage(name: "not-an-image.txt", mimeType: "text/plain", base64Data: "aGVsbG8=")]
        )
        let notice = AIService.imageNotice(note: note, configuration: configuration)
        XCTAssertTrue(notice.contains("无法识别笔记中的图片"))
    }

    func testVisionPayloadAppliesImageBudget() throws {
        let configuration = AIProviderConfiguration(kind: .openAI, model: "gpt-4o", apiKey: "test")
        let oversized = String(repeating: "a", count: 3_000_000)
        let image = NoteImage(name: "large.png", mimeType: "image/png", base64Data: oversized)
        let request = try AIService.requestForTesting(configuration: configuration, context: "read", images: [image])
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertLessThan(body.count, 100_000)
    }

    func testEmbeddedHTMLImageDataIsRemovedBeforeContextConstruction() throws {
        let embedded = String(repeating: "A", count: 2_000_000)
        let html = "<p>before</p><img src=\"data:image/png;base64,\(embedded)\"><p>after</p>"
        let sanitized = AIService.sanitizedRichTextForTesting(html)
        XCTAssertLessThan(sanitized.count, 200_000)
        XCTAssertFalse(sanitized.contains(embedded))
        XCTAssertTrue(sanitized.contains("embedded image omitted"))
    }

    func testAskCanReturnReviewableProposalWhenUserRequestsAnEdit() throws {
        let input = #"{"answer":"我已准备好整理后的版本，请确认修改。","proposal":{"title":"整理后的笔记","blocks":[]}}"#

        let response = try AIService.decodeResponse(input, action: .ask)

        XCTAssertEqual(response.answer, "我已准备好整理后的版本，请确认修改。")
        XCTAssertEqual(response.proposal?.title, "整理后的笔记")
    }

    func testConversationalAskCanReturnAnswerWithoutProposal() throws {
        let input = #"{"answer":"这份笔记结构清晰，但需要补充优先级。","proposal":null}"#

        let response = try AIService.decodeResponse(input, action: .ask)

        XCTAssertEqual(response.answer, "这份笔记结构清晰，但需要补充优先级。")
        XCTAssertNil(response.proposal)
    }

    func testResponseAcceptsUppercaseFenceAndSurroundingText() throws {
        let input = """
        Here is the result:
        ```JSON
        {"answer":"图片内容已识别。","proposal":null}
        ```
        """

        let response = try AIService.decodeResponse(input, action: .ask)

        XCTAssertEqual(response.answer, "图片内容已识别。")
        XCTAssertNil(response.proposal)
    }

    func testResponseJSONExtractionIgnoresBracesInsideAnswer() throws {
        let input = #"Result: {"answer":"Use {name} in the template.","proposal":null} Done."#

        let response = try AIService.decodeResponse(input, action: .ask)

        XCTAssertEqual(response.answer, "Use {name} in the template.")
    }

    func testMalformedJSONNeverAppearsInReadOnlyConversation() throws {
        let input = #"{"answer":"这份笔记目标明确，建议增加时间节点和回顾机制。","proposal":{"title":"截断的内容","blocks":[{"kind":"heading"}]"#

        let response = try AIService.decodeResponse(input, action: .ask)

        XCTAssertEqual(response.answer, "这份笔记目标明确，建议增加时间节点和回顾机制。")
        XCTAssertFalse(response.answer.contains("proposal"))
        XCTAssertNil(response.proposal)
    }

    func testSummarizeReturnsSummaryTextWithoutProposal() throws {
        let input = #"{"answer":"笔记主要规划了课程学习、科研、英语考试和实习申请，并给出了阶段性目标。","proposal":null}"#

        let response = try AIService.decodeResponse(input, action: .summarize)

        XCTAssertEqual(response.answer, "笔记主要规划了课程学习、科研、英语考试和实习申请，并给出了阶段性目标。")
        XCTAssertNil(response.proposal)
    }

    func testSummarizeDiscardsUnexpectedProposal() throws {
        let input = #"{"answer":"笔记总结了学习和求职目标。","proposal":{"title":"不应修改","blocks":[]}}"#

        let response = try AIService.decodeResponse(input, action: .summarize)

        XCTAssertEqual(response.answer, "笔记总结了学习和求职目标。")
        XCTAssertNil(response.proposal)
    }

    func testSummaryCompletionNoticeIsNotSubstantive() {
        XCTAssertFalse(AIService.isSubstantiveSummary(
            "I summarized the note while preserving its key structure and action items."
        ))
        XCTAssertFalse(AIService.isSubstantiveSummary("我已经总结了这份笔记。"))
    }

    func testConcreteSummaryIsSubstantive() {
        XCTAssertTrue(AIService.isSubstantiveSummary(
            "这份笔记规划了课程学习、科研和实习申请，并要求在暑假前完成英语考试与技术准备。"
        ))
    }
}
