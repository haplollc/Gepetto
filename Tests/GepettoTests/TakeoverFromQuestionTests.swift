import XCTest
import WebKit
@testable import Gepetto

/// Replies with one scripted JSON decision per call.
private final class ReplyEngine: GepettoAIEngine, @unchecked Sendable {
    var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func stream(messages: [GepettoMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        let reply = replies.isEmpty ? #"{"action":{"name":"done","answer":"ok","success":true}}"# : replies.removeFirst()
        return AsyncThrowingStream { c in c.yield(reply); c.finish() }
    }
}

@MainActor
final class TakeoverFromQuestionTests: XCTestCase {
    func testTakeOverFromTheQuestionCardHandsThePageOver() async throws {
        let agent = BrowserAgent()
        agent.start()
        defer { agent.shutdown() }
        let engine = ReplyEngine([
            #"{"thought":"ask","action":{"name":"ask_user","question":"Sign in please?"}}"#,
            #"{"thought":"finish","action":{"name":"done","answer":"thanks","success":true}}"#
        ])
        var states: [String] = []
        let run = Task { await agent.run(task: "Open the page so I can sign in", engine: engine) { event in
            if case .control(let s) = event { states.append("\(s)") }
        } }
        // Wait for the question.
        for _ in 0..<100 {
            if case .waitingForUser(.question) = agent.controlState { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .waitingForUser(.question) = agent.controlState else { return XCTFail("never asked: \(agent.controlState)") }
        agent.takeOver()
        for _ in 0..<60 {
            if case .waitingForUser(.takeover) = agent.controlState { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(agent.controlState.isHumanDriving, "after Take over: \(agent.controlState) via \(states)")
        agent.handBack(note: "done")
        _ = await run.value
    }
}
