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
            #"{"thought":"ask","action":{"name":"ask_user","question":"Which color do you want?"}}"#,
            #"{"thought":"finish","action":{"name":"done","answer":"thanks","success":true}}"#
        ])
        var states: [String] = []
        let run = Task { await agent.run(task: "Pick a cup for me", engine: engine) { event in
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

    /// "hand_over", and a question that is really "sign in yourself", give
    /// the person the page at once: no answer box, no extra tap.
    func testSignInRequestsHandThePageOverAtOnce() async throws {
        for reply in [#"{"thought":"you","action":{"name":"hand_over","reason":"Sign in to the store"}}"#,
                      #"{"thought":"you","action":{"name":"ask_user","question":"Please sign in with your password"}}"#] {
            let agent = BrowserAgent()
            agent.start()
            let engine = ReplyEngine([reply, #"{"thought":"finish","action":{"name":"done","answer":"thanks","success":true}}"#])
            var sawQuestion = false
            let run = Task { await agent.run(task: "Check my orders", engine: engine) { event in
                if case .control(.waitingForUser(.question)) = event { sawQuestion = true }
            } }
            for _ in 0..<100 {
                if agent.controlState.isHumanDriving { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(agent.controlState.isHumanDriving, "\(reply): \(agent.controlState)")
            XCTAssertFalse(sawQuestion, "a sign-in request must not show an answer box")
            agent.handBack()
            _ = await run.value
            agent.shutdown()
        }
    }

    func testWhichQuestionsNeedThePersonOnThePage() {
        XCTAssertTrue(AgentLoopHeuristics.needsThePersonOnThePage("Could you sign in to Medium?"))
        XCTAssertTrue(AgentLoopHeuristics.needsThePersonOnThePage("Enter the verification code from your phone"))
        XCTAssertTrue(AgentLoopHeuristics.needsThePersonOnThePage("Please type your password"))
        XCTAssertFalse(AgentLoopHeuristics.needsThePersonOnThePage("Which color do you want?"))
        XCTAssertFalse(AgentLoopHeuristics.needsThePersonOnThePage("Should I pick the cheaper one?"))
    }
}
