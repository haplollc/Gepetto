<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2016%2B%20%7C%20macOS%2013%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange" alt="Swift">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License">
</p>

<h1 align="center">🎭 Gepetto</h1>

<p align="center">
  <strong>The puppet master for browser automation</strong><br>
  <em>Control the web like strings on a marionette</em>
</p>

<p align="center">
  Navigate • Extract • Interact • Screenshot
</p>

---

Gepetto provides **programmatic control** over a WKWebView-based browser, enabling AI agents to browse the web, fill forms, click elements, take screenshots, and extract content — all from Swift.

## ✨ Features

| Category | Capabilities |
|----------|-------------|
| 🧭 **Navigation** | Load URLs, go back/forward, reload, wait for load |
| 📸 **Screenshots** | Capture viewport or full scrollable page as PNG |
| 📝 **Form Filling** | Fill inputs, select dropdowns, check boxes, submit |
| 🖱️ **Interactions** | Click elements, type text, scroll in any direction |
| 📄 **Extraction** | Get text, HTML, all links, form fields |
| ⏳ **Waiting** | Wait for elements, text, or navigation to complete |
| 🤖 **AI Ready** | JSON schema for LLM function calling |
| 🧠 **Agent SDK** | Plug-and-play `BrowserAgent` with multi-stage automation, AI validation, and form-fill takeover — bring your own model via the `GepettoAIEngine` protocol |
| 🎨 **SwiftUI** | Drop-in views, sheets, and modifiers |

---

## 📦 Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/haplollc/Gepetto.git", from: "1.0.0")
]
```

**Or in Xcode:**

1. File → Add Package Dependencies
2. Enter: `https://github.com/haplollc/Gepetto.git`
3. Click Add Package

---

## 🚀 Quick Start

### Highest level: `BrowserAgent` (LLM-driven, multi-step)

The fastest way to get a real browser agent in your app. `BrowserAgent` runs a full multi-step automation loop on top of any AI backend — your local model, Apple Foundation Models, OpenAI, Anthropic, anything that can stream a text completion. You implement one tiny adapter, then call `run(task:)` with a natural-language instruction.

```swift
import Gepetto

// 1. Implement GepettoAIEngine for your model of choice.
final class MyEngine: GepettoAIEngine, @unchecked Sendable {
    func stream(messages: [GepettoMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Call your LLM (OpenAI, local Llama, Foundation Models, etc.)
                // and yield each text chunk:
                continuation.yield("Hello ")
                continuation.yield("world")
                continuation.finish()
            }
        }
    }
}

// 2. Boot the agent and run a task.
let agent = BrowserAgent()       // headless WKWebView is set up automatically
let engine = MyEngine()

await agent.run(
    task: """
    Go to https://news.ycombinator.com, click into the top story, \
    and tell me what it's about in one sentence.
    """,
    engine: engine
) { event in
    switch event {
    case .textChunk(let s):       print(s, terminator: "")
    case .action(let name, _):    print("\n[\(name)]")
    case .actionResult:           break
    case .validation(let i, let ok, let why):
        print("\n[stage \(i + 1) validation: \(ok ? "OK" : "FAIL") — \(why)]")
    case .complete(let final):    print("\n\(final)")
    case .failed(let reason, _):  print("\n❌ \(reason)")
    case .replaceText(let t):     print("\n[clear → \(t)]")
    }
}
```

What you get out of the box:

- **Multi-stage automation**: a single prompt with multiple URLs becomes an ordered chain of `(URL → form-fill → submit)` stages, each driven deterministically.
- **Per-stage AI validation**: after every stage, the agent asks your engine *"did this step actually succeed?"* and aborts cleanly on failure (catches login errors, validation messages, 404s) instead of plowing through bad state.
- **Form-fill takeover**: when your prompt says *"type X into the username field"*, Gepetto runs `extract_forms`, matches selectors heuristically (by `name` / `type` / `placeholder`), and fills them — even if the AI fumbles selectors.
- **Refusal recovery**: weak local models that say *"I can't browse"* get nudged once, then deterministically driven to a content link from the page on the second try.
- **Live `WKWebView`**: `agent.executor?.engine?.webView` is the actual driving webview. Drop it into a SwiftUI `UIViewRepresentable` to show automation in real time.

```swift
agent.configuration = BrowserAgentConfiguration(
    maxIterations: 8,         // loop cap
    validateEachStage: true,  // ask the AI to validate each stage's outcome
    visualPaceMs: 800,        // ms pause between actions so UI updates are visible
    headlessViewport: CGSize(width: 1024, height: 1366)
)
```

See [HaploAI iOS](https://github.com/haplollc/HaploAI_iOS) for the on-device LLM adapter (`LocalLLMEngineAdapter`) — a complete real-world example.

---

### Lower level: `BrowserToolExecutor` (single-action, no AI)

The same primitive `BrowserAgent` uses internally. Reach for this when you want to drive the browser yourself without an LLM in the loop — your own deterministic scripts, MCP tool dispatch, function-calling backends, etc.

```swift
import Gepetto

let executor = BrowserToolExecutor()

// Navigate to a page
await executor.execute(
    BrowserTool.Parameters(action: .navigate, url: "https://example.com")
)

// Take a screenshot for vision model
let screenshot = await executor.execute(
    BrowserTool.Parameters(action: .screenshot, fullPage: true)
)
// screenshot.screenshot contains PNG data

// Extract all text
let text = await executor.execute(
    BrowserTool.Parameters(action: .extractText)
)
print(text.data!) // Page content

// Fill a form
await executor.execute(
    BrowserTool.Parameters(action: .fill, selector: "#email", text: "user@example.com")
)

// Click submit
await executor.execute(
    BrowserTool.Parameters(action: .click, selector: "#submit")
)
```

### Direct Engine Control

```swift
import Gepetto

let engine = BrowserEngine()

// Navigate
try await engine.navigate(to: "https://apple.com")

// Wait for element
try await engine.waitForElement(selector: ".hero-headline")

// Extract content
let title = try await engine.getTitle()
let links = try await engine.extractLinks()

// Take screenshot
let imageData = try await engine.screenshot(fullPage: true)

// Interact
try await engine.click(selector: ".shop-button")
try await engine.fill(selector: "#search", text: "MacBook Pro")
try await engine.type(selector: "#search", text: "M3 Max", delay: 50)
```

---

## 🎨 SwiftUI Integration

### Browser Sheet

```swift
import SwiftUI
import Gepetto

struct ContentView: View {
    @StateObject var executor = BrowserToolExecutor()
    @State var showBrowser = false
    
    var body: some View {
        Button("🌐 Open Browser") { 
            showBrowser = true 
        }
        .browserSheet(
            isPresented: $showBrowser,
            executor: executor,
            initialURL: "https://apple.com"
        )
    }
}
```

### Embedded Browser View

```swift
struct BrowserPage: View {
    @StateObject var engine = BrowserEngine()
    
    var body: some View {
        VStack(spacing: 0) {
            BrowserNavBar(engine: engine)
            BrowserView(engine: engine, showNavBar: false)
        }
        .task {
            try? await engine.navigate(to: "https://example.com")
        }
    }
}
```

### Full Screen Browser

```swift
.browserFullScreen(
    isPresented: $showBrowser,
    executor: executor,
    initialURL: "https://google.com",
    title: "Search"
)
```

---

## 🤖 LLM Function Calling

Gepetto provides a ready-to-use JSON schema for AI function calling:

```swift
// Get the schema for your LLM
let schema = BrowserTool.jsonSchema

// Execute actions from LLM responses
let params: [String: Any] = [
    "action": "navigate",
    "url": "https://example.com"
]
let result = await executor.execute(json: params)
```

### Compact Schema (for context)

```
browser(action, url?, selector?, text?, script?, direction?, fullPage?, ...)

Actions:
- navigate(url): Go to URL
- screenshot(fullPage?): Capture page as PNG
- extract_text: Get all text content
- extract_links: Get all links [{href, text}]
- extract_forms: Get form fields [{selector, type, name}]
- click(selector): Click element
- click_text(text, tag?): Click by visible text
- fill(selector, text): Fill input field
- type(selector, text, delay?): Type with keystrokes
- select(selector, value): Select dropdown option
- scroll(direction): Scroll up/down/left/right
- scroll_to(selector): Scroll element into view
- wait_for_element(selector, timeout?): Wait for element
- wait_for_text(text, timeout?): Wait for text to appear
- evaluate(script): Execute JavaScript
```

---

## 📋 All Actions

| Action | Required Params | Description |
|--------|----------------|-------------|
| `navigate` | `url` | Navigate to URL |
| `go_back` | - | Go back in history |
| `go_forward` | - | Go forward in history |
| `reload` | - | Reload current page |
| `screenshot` | `fullPage?` | Capture page as PNG |
| `extract_text` | - | Get page text content |
| `extract_html` | `selector?` | Get HTML (all or element) |
| `extract_links` | - | Get all links on page |
| `extract_forms` | - | Get form field info |
| `get_title` | - | Get page title |
| `get_url` | - | Get current URL |
| `click` | `selector` | Click element |
| `click_text` | `text`, `tag?` | Click by visible text |
| `fill` | `selector`, `text` | Fill input field |
| `type` | `selector`, `text`, `delay?` | Type with keystrokes |
| `clear` | `selector` | Clear input field |
| `submit` | `selector` | Submit form |
| `select` | `selector`, `value` | Select dropdown option |
| `set_checked` | `selector`, `checked` | Check/uncheck checkbox |
| `scroll` | `direction` | Scroll (up/down/left/right) |
| `scroll_to` | `selector` | Scroll to element |
| `scroll_to_top` | - | Scroll to top |
| `scroll_to_bottom` | - | Scroll to bottom |
| `wait_for_element` | `selector`, `timeout?` | Wait for element |
| `wait_for_text` | `text`, `timeout?` | Wait for text |
| `wait_for_navigation` | `timeout?` | Wait for page load |
| `evaluate` | `script` | Execute JavaScript |

---

## 🔍 Example: AI Web Research Agent

```swift
class WebResearchAgent {
    let executor = BrowserToolExecutor()
    
    func research(_ query: String) async -> ResearchResult {
        // 1. Go to search engine
        await executor.execute(
            BrowserTool.Parameters(action: .navigate, url: "https://google.com")
        )
        
        // 2. Type search query
        await executor.execute(
            BrowserTool.Parameters(
                action: .type, 
                selector: "textarea[name=q]", 
                text: query,
                delay: 30
            )
        )
        
        // 3. Submit search
        await executor.execute(
            BrowserTool.Parameters(
                action: .evaluate, 
                script: "document.querySelector('form').submit()"
            )
        )
        
        // 4. Wait for results
        await executor.execute(
            BrowserTool.Parameters(
                action: .waitForElement, 
                selector: "#search",
                timeout: 10
            )
        )
        
        // 5. Screenshot for vision model
        let screenshot = await executor.execute(
            BrowserTool.Parameters(action: .screenshot)
        )
        
        // 6. Extract links
        let links = await executor.execute(
            BrowserTool.Parameters(action: .extractLinks)
        )
        
        // 7. Get text summary
        let text = await executor.execute(
            BrowserTool.Parameters(action: .extractText)
        )
        
        return ResearchResult(
            screenshot: screenshot.screenshot,
            links: links.links ?? [],
            textContent: text.data ?? ""
        )
    }
}
```

---

## 🌍 Real-World Usage

Gepetto powers the in-chat browser agent in **[HaploAI iOS](https://github.com/haplollc/HaploAI_iOS)** — a fully on-device AI assistant where the local LLM drives a live `WKWebView` to navigate, click, fill forms, and extract content for the user. The integration showcases a battle-tested pattern for shipping browser automation in production:

- **Inline live panel** — the actual `WKWebView` Gepetto is driving renders right above the chat input, so the user watches automation happen in real time.
- **Multi-step agent loop** — the LLM emits `<tool_call>` blocks, results are fed back into the next iteration, until a final natural-language answer.
- **Deterministic form-fill takeover** — when the LLM fumbles selectors, the wrapper extracts real fields via `extract_forms` and fills them by name/type heuristics so a weak local model can still complete a form and click submit.
- **Auto-content-click** — when the user says *"click into the top story"*, the wrapper picks the first external link from the latest snapshot and navigates deterministically.
- **Multi-stage scripted automation** — a single user prompt can describe a chain of (URL + form-fill + submit) stages (e.g. *"log in at /login, then go to /submit and post X"*); the runner detects the multiple URLs, parses each segment for typing intent, and drives every stage end-to-end deterministically. The LLM is only invoked at the end for a 1–2-sentence summary based on the final page state, so weak local models can complete complex multi-page flows reliably.

See [HaploAI iOS](https://github.com/haplollc/HaploAI_iOS) for the full agent runner, the live SwiftUI panel, and integration tests.

---

## 🪟 Headless / Agent-Driven Usage

When Gepetto is driven from an agent loop (no user-visible UI), the `WKWebView` ends up offscreen with `frame: .zero` and never gets attached to a window. WebKit needs a non-zero layout context for several APIs to work correctly:

- `document.body.innerText` returns `""` when there's no rendered layout.
- `WKWebView.takeSnapshot` produces a zero-size image that fails PNG encoding.
- `evaluateJavaScript` works fine, but anything depending on rendered geometry (clientWidth, etc.) won't.

**Two recommended fixes** (use either):

1. **Park the webview in a hidden window** with a real viewport so it actually lays out:

   ```swift
   let executor = BrowserToolExecutor()
   executor.start()
   if let webView = executor.engine?.webView {
       webView.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
       #if os(iOS)
       let window = UIWindow(frame: webView.frame)
       window.alpha = 0
       window.isUserInteractionEnabled = false
       window.rootViewController = UIViewController()
       window.rootViewController?.view.addSubview(webView)
       window.isHidden = false
       #elseif os(macOS)
       let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
       window.alphaValue = 0
       window.contentView?.addSubview(webView)
       #endif
   }
   ```

2. **Use `extractText` directly** — as of v1.0.1 the engine falls back to `document.body.textContent` when `innerText` returns empty, so headless extraction works even without a layout context. Note `textContent` returns *all* text including hidden elements, which is usually preferable for LLM consumption anyway.

Both approaches can be combined for maximum reliability.

---

## 🧪 Testing

```bash
# Run all tests
swift test

# Run specific test file
swift test --filter BrowserToolTests
```

**56 tests** covering:
- Action encoding/decoding
- JSON schema structure
- Error handling
- Executor lifecycle
- Parameter validation

---

## 📱 Platform Support

| Platform | Minimum Version | Status |
|----------|----------------|--------|
| iOS | 16.0 | ✅ Full Support |
| macOS | 13.0 | ✅ Full Support |
| iPadOS | 16.0 | ✅ Full Support |
| Mac Catalyst | 16.0 | ✅ Full Support |

---

## 🏗️ Architecture

```
Gepetto
├── Core
│   ├── BrowserEngine      # WKWebView controller (actor)
│   ├── BrowserTypes       # Configuration, results, info structs
│   └── BrowserError       # Error types with user messages
├── Tool
│   ├── BrowserTool        # LLM schema (Action, Parameters, Result)
│   └── BrowserToolExecutor # Execute actions, manage lifecycle
└── Views
    ├── BrowserView        # SwiftUI WKWebView wrapper
    ├── BrowserNavBar      # URL bar with back/forward
    └── BrowserSheet       # Modal presentation
```

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

---

<p align="center">
  Built with ❤️ by <a href="https://github.com/haplollc">Haplo LLC</a>
</p>
