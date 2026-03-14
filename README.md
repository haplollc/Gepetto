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

### For AI Agents (Tool Executor)

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
