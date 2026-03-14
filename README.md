# BrowserKit 🌐

**iOS/macOS browser automation for AI agents.**

BrowserKit provides programmatic control over a WKWebView-based browser, enabling AI agents to navigate the web, fill forms, click elements, take screenshots, and extract content — all from Swift.

## Features

- 🧭 **Navigation**: Load URLs, go back/forward, reload
- 📸 **Screenshots**: Capture viewport or full page
- 📝 **Form Filling**: Fill inputs, select dropdowns, check boxes
- 🖱️ **Interactions**: Click elements, type text, scroll
- 📄 **Content Extraction**: Get text, HTML, links, form fields
- ⏳ **Waiting**: Wait for elements, text, or navigation
- 🤖 **LLM Tool Schema**: Ready-to-use JSON schema for function calling
- 🎨 **SwiftUI Views**: Drop-in browser views and sheets

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/haplollc/BrowserKit.git", from: "1.0.0")
]
```

Or in Xcode: File → Add Package Dependencies → Enter URL:
```
https://github.com/haplollc/BrowserKit.git
```

## Quick Start

### Basic Usage

```swift
import BrowserKit

// Create an executor for AI tool calls
let executor = BrowserToolExecutor()

// Navigate to a page
let result = await executor.execute(
    BrowserTool.Parameters(action: .navigate, url: "https://example.com")
)

// Take a screenshot
let screenshot = await executor.execute(
    BrowserTool.Parameters(action: .screenshot, fullPage: true)
)
// screenshot.screenshot contains PNG data

// Extract text
let text = await executor.execute(
    BrowserTool.Parameters(action: .extractText)
)
print(text.data) // All text on the page

// Fill a form
await executor.execute(
    BrowserTool.Parameters(action: .fill, selector: "#email", text: "user@example.com")
)

// Click a button
await executor.execute(
    BrowserTool.Parameters(action: .click, selector: "#submit")
)
```

### Direct Engine Access

For more control, use `BrowserEngine` directly:

```swift
let engine = BrowserEngine()

// Navigate
try await engine.navigate(to: "https://example.com")

// Take screenshot
let imageData = try await engine.screenshot(fullPage: true)

// Fill form
try await engine.fill(selector: "#search", text: "query")

// Click
try await engine.click(selector: ".search-button")

// Wait for results
try await engine.waitForElement(selector: ".results")

// Extract
let text = try await engine.extractText()
```

### SwiftUI Integration

```swift
struct ContentView: View {
    @StateObject var executor = BrowserToolExecutor()
    @State var showBrowser = false
    
    var body: some View {
        Button("Open Browser") { 
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

Or use `BrowserView` directly:

```swift
struct BrowserPage: View {
    @StateObject var engine = BrowserEngine()
    
    var body: some View {
        BrowserView(engine: engine)
            .task {
                try? await engine.navigate(to: "https://example.com")
            }
    }
}
```

## LLM Tool Integration

BrowserKit provides a JSON schema for LLM function calling:

```swift
// Get the tool schema
let schema = BrowserTool.jsonSchema

// Execute from JSON (from LLM response)
let params: [String: Any] = [
    "action": "navigate",
    "url": "https://example.com"
]
let result = await executor.execute(json: params)
```

### Available Actions

| Action | Parameters | Description |
|--------|------------|-------------|
| `navigate` | `url` | Navigate to URL |
| `go_back` | - | Go back in history |
| `go_forward` | - | Go forward in history |
| `reload` | - | Reload current page |
| `screenshot` | `fullPage?` | Capture page as PNG |
| `extract_text` | - | Get page text content |
| `extract_html` | `selector?` | Get HTML (all or element) |
| `extract_links` | - | Get all links on page |
| `extract_forms` | - | Get form fields |
| `click` | `selector` | Click element |
| `click_text` | `text`, `tag?` | Click element by text |
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

## Example: AI Web Research

```swift
class AIBrowser {
    let executor = BrowserToolExecutor()
    
    func research(query: String) async -> String {
        // Navigate to search engine
        await executor.execute(
            BrowserTool.Parameters(action: .navigate, url: "https://google.com")
        )
        
        // Type search query
        await executor.execute(
            BrowserTool.Parameters(action: .type, selector: "input[name=q]", text: query)
        )
        
        // Press Enter (submit)
        await executor.execute(
            BrowserTool.Parameters(action: .evaluate, script: "document.querySelector('input[name=q]').form.submit()")
        )
        
        // Wait for results
        await executor.execute(
            BrowserTool.Parameters(action: .waitForElement, selector: "#search")
        )
        
        // Take screenshot for vision model
        let screenshot = await executor.execute(
            BrowserTool.Parameters(action: .screenshot)
        )
        
        // Extract text
        let text = await executor.execute(
            BrowserTool.Parameters(action: .extractText)
        )
        
        return text.data ?? ""
    }
}
```

## Requirements

- iOS 16.0+ / macOS 13.0+
- Swift 5.9+
- Xcode 15.0+

## License

MIT License - see [LICENSE](LICENSE) for details.

## Author

Created by [Haplo LLC](https://github.com/haplollc)
