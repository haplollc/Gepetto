import XCTest
import Network
import WebKit
@testable import Gepetto
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A tiny local web server, so the agent browses a real page over HTTP with
/// nothing from the internet involved.
private final class LocalSite: @unchecked Sendable {
    private let listener: NWListener
    private let pages: @Sendable (String) -> String
    let port: UInt16

    init(pages: @escaping @Sendable (String) -> String) throws {
        self.pages = pages
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [pages] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body = Data(pages(path).utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }
}

/// A shop with a search box: the task needs typing, a submit and reading the
/// results page.
private let shopPages: @Sendable (String) -> String = { path in
    if path.hasPrefix("/search") {
        let query = (URLComponents(string: path)?.queryItems?.first { $0.name == "q" }?.value ?? "").lowercased()
        let found = query.contains("mug")
        return """
        <html><head><title>Search results</title></head><body>
        <h1>Results for \(query)</h1>
        \(found ? "<ul><li><a href='/p/blue-mug'>Blue Ceramic Mug</a> <span>$14.50</span></li><li><a href='/p/red-mug'>Red Ceramic Mug</a> <span>$12.00</span></li></ul>" : "<p>No products found.</p>")
        </body></html>
        """
    }
    return """
    <html><head><title>Corner Shop</title></head><body>
    <h1>Corner Shop</h1>
    <form action="/search" method="get">
      <label for="q">Search products</label>
      <input id="q" name="q" type="search" placeholder="Search products">
      <button type="submit">Search</button>
    </form>
    <p>Free delivery on orders over $30.</p>
    </body></html>
    """
}

/// A page with far more on it than a small model can read at once.
private let busyPage: @Sendable (String) -> String = { _ in
    let links = (1...300).map { "<a href=\"/item/\($0)\">Product number \($0) with a fairly long descriptive name</a>" }.joined(separator: "<br>")
    let text = String(repeating: "Lots of descriptive page copy about products, prices and delivery options. ", count: 80)
    return "<html><head><title>Busy</title></head><body><h1>Everything</h1><p>\(text)</p>\(links)</body></html>"
}

/// Accepts only prompts up to `limit` characters and records what it got.
private final class TightEngine: GepettoPromptLimitedEngine, @unchecked Sendable {
    let limit: Int
    var asked: [Int] = []
    var sent: [String] = []
    init(limit: Int) { self.limit = limit }
    func promptFits(_ prompt: String) async -> Bool {
        asked.append(prompt.count)
        return prompt.count <= limit
    }
    func stream(messages: [GepettoMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        sent.append(messages.last?.content ?? "")
        let reply = #"{"thought":"done","action":{"name":"done","answer":"ok","success":true}}"#
        return AsyncThrowingStream { c in c.yield(reply); c.finish() }
    }
}

@MainActor
final class AppleIntelligenceAgentTests: XCTestCase {

    /// The ladder only ever shows less, rung by rung.
    func testThePromptLadderShrinksStepByStep() {
        let full = AgentLoopLadderProbe.full
        let ladder = BrowserAgent.promptDetailLadder(from: full)
        XCTAssertEqual(ladder.first, full)
        XCTAssertGreaterThan(ladder.count, 4)
        for (a, b) in zip(ladder, ladder.dropFirst()) {
            XCTAssertLessThanOrEqual(b.maxElements, a.maxElements)
            XCTAssertLessThanOrEqual(b.maxTextChars, a.maxTextChars)
            XCTAssertLessThanOrEqual(b.historyWindow, a.historyWindow)
            XCTAssertLessThanOrEqual(b.maxStepLineChars, a.maxStepLineChars)
            XCTAssertNotEqual(a, b)
        }
        XCTAssertEqual(ladder.last?.maxTextChars, 0)
        XCTAssertEqual(ladder.last?.conversationTurns, 0)
    }

    /// A prompt-limited engine is sent the fullest prompt it accepts, on a
    /// real page in a real web view.
    func testALimitedEngineGetsAPromptThatFits() async throws {
        let site = try LocalSite(pages: busyPage)
        let agent = BrowserAgent()
        agent.start()
        defer { agent.shutdown() }
        let limit = 5_000
        let engine = TightEngine(limit: limit)
        await agent.run(task: "Open http://127.0.0.1:\(site.port)/ and tell me the page heading.", engine: engine) { _ in }
        let prompt = try XCTUnwrap(engine.sent.first)
        print("🍏 LIMITED asked=\(engine.asked) sent=\(prompt.count)")
        XCTAssertLessThanOrEqual(prompt.count, limit)
        XCTAssertGreaterThan(engine.asked.count, 1, "the full prompt should not have fit: \(engine.asked)")
        XCTAssertGreaterThan(prompt.count, limit / 2, "the fullest prompt that fits, not the smallest")
        XCTAssertTrue(prompt.contains("TASK: Open http://127.0.0.1"), "the task is always kept")
        XCTAssertTrue(prompt.contains("TITLE: Busy"), "the page is still described")
    }

    #if canImport(FoundationModels)
    /// Apple's on-device model drives the agent end to end: it opens the
    /// shop, searches, and answers from the results page.
    func testAppleIntelligenceSearchesAShopAndReadsThePrice() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        guard FoundationModelsEngine.isAvailable else {
            throw XCTSkip(FoundationModelsEngine.unavailableReason ?? "Apple Intelligence unavailable")
        }
        let site = try LocalSite(pages: shopPages)
        let agent = BrowserAgent()
        agent.start()
        defer { agent.shutdown() }
        let engine = FoundationModelsEngine()
        var actions: [String] = []
        var answer = ""
        var failure: String?
        let started = Date()
        await agent.run(task: "Go to http://127.0.0.1:\(site.port)/ and search the shop for a blue mug. What does the blue mug cost?",
                        engine: engine) { event in
            switch event {
            case .action(let name, let args): actions.append("\(name) \(args)")
            case .complete(let text): answer = text
            case .failed(let reason, _): failure = reason
            default: break
            }
        }
        let seconds = Int(Date().timeIntervalSince(started))
        print("🍏 APPLE RUN \(seconds)s actions=\(actions)")
        print("🍏 APPLE ANSWER \(answer)")
        for step in agent.steps { print("🍏 STEP \(step.historyLine.prefix(160))") }
        XCTAssertNil(failure, "run failed: \(failure ?? "")")
        XCTAssertTrue(answer.contains("14.50"), "answer: \(answer)")
        XCTAssertTrue(agent.steps.contains { if case .type = $0.action { return true }; return false }, "it should have typed the search")
    }

    /// The prompt the agent builds for a busy page fits Apple's window once
    /// fitted, counted by Apple's own tokenizer.
    func testABusyPageIsFittedToTheAppleWindow() async throws {
        guard #available(iOS 26.4, macOS 26.4, *) else { throw XCTSkip("needs exact token counts") }
        guard FoundationModelsEngine.isAvailable else { throw XCTSkip("Apple Intelligence unavailable") }
        let site = try LocalSite(pages: busyPage)
        let agent = BrowserAgent()
        agent.start()
        defer { agent.shutdown() }
        let engine = FoundationModelsEngine()
        let recorder = RecordingEngine(inner: engine)
        await agent.run(task: "Open http://127.0.0.1:\(site.port)/ and tell me the page heading.", engine: recorder) { _ in }
        let prompt = try XCTUnwrap(recorder.prompts.first)
        let tokens = await engine.promptTokens(prompt)
        print("🍏 BUSY PAGE prompt chars=\(prompt.count) tokens=\(tokens) context=\(SystemLanguageModel.default.contextSize)")
        XCTAssertLessThanOrEqual(tokens + engine.replyTokens, SystemLanguageModel.default.contextSize)
    }
    #endif
}

/// The configuration's full detail, as the loop computes it.
@MainActor
private enum AgentLoopLadderProbe {
    static var full: BrowserAgent.PromptDetail { BrowserAgent().fullPromptDetail }
}

#if canImport(FoundationModels)
/// Passes calls through to a real engine and keeps the prompts it was sent.
@available(iOS 26.0, macOS 26.0, *)
private final class RecordingEngine: GepettoPromptLimitedEngine, @unchecked Sendable {
    let inner: FoundationModelsEngine
    var prompts: [String] = []
    init(inner: FoundationModelsEngine) { self.inner = inner }
    func promptFits(_ prompt: String) async -> Bool { await inner.promptFits(prompt) }
    func stream(messages: [GepettoMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        prompts.append(messages.last?.content ?? "")
        return inner.stream(messages: messages, systemPrompt: systemPrompt)
    }
}
#endif
