# BrowserKit Implementation Plan

## Overview

BrowserKit is an iOS/macOS browser automation library for AI agents. It provides programmatic control over WKWebView, enabling AI systems to browse the web, fill forms, extract content, and take screenshots.

## Goals

1. **Cross-platform**: Support iOS 16+ and macOS 13+
2. **AI-ready**: JSON schema for LLM function calling
3. **Full automation**: Navigate, interact, extract, screenshot
4. **SwiftUI integration**: Drop-in views and modifiers
5. **Testable**: Comprehensive unit test coverage
6. **CI/CD**: Automated testing on all PRs

---

## Architecture

```
BrowserKit/
├── Sources/BrowserKit/
│   ├── Core/
│   │   ├── BrowserEngine.swift      # Main WKWebView controller
│   │   ├── BrowserTypes.swift       # Supporting types
│   │   └── BrowserError.swift       # Error definitions
│   ├── Tool/
│   │   ├── BrowserTool.swift        # LLM tool schema
│   │   └── BrowserToolExecutor.swift # Execute tool actions
│   └── Views/
│       ├── BrowserView.swift        # SwiftUI browser view
│       └── BrowserSheet.swift       # Presentable sheet
├── Tests/BrowserKitTests/
│   ├── BrowserToolTests.swift       # Tool schema tests
│   ├── BrowserTypesTests.swift      # Type tests
│   ├── BrowserEngineTests.swift     # Engine tests
│   └── BrowserIntegrationTests.swift # End-to-end tests
└── .github/workflows/
    └── tests.yml                    # CI configuration
```

---

## Implementation Phases

### Phase 1: Core Engine ✅
- [x] BrowserEngine actor with WKWebView
- [x] Navigation (navigate, back, forward, reload)
- [x] Content extraction (text, HTML, links, forms)
- [x] Interactions (click, fill, type, select, scroll)
- [x] Screenshots (viewport, full page)
- [x] Waiting (element, text, navigation)
- [x] JavaScript evaluation
- [x] Platform-specific code (iOS/macOS)

### Phase 2: Tool System ✅
- [x] BrowserTool action enum (30+ actions)
- [x] Parameters struct (Codable)
- [x] Result struct with data/screenshot/links
- [x] JSON schema for LLM function calling
- [x] BrowserToolExecutor for action dispatch

### Phase 3: SwiftUI Views ✅
- [x] BrowserView (WKWebView wrapper)
- [x] BrowserNavBar (URL bar, back/forward)
- [x] BrowserSheet (modal presentation)
- [x] BrowserAIIndicator (AI control status)
- [x] View modifiers (.browserSheet, .browserFullScreen)

### Phase 4: Testing ✅
- [x] BrowserToolTests (action encoding/decoding)
- [x] BrowserTypesTests (configuration, results)
- [x] JSON schema validation tests
- [ ] BrowserEngineTests (mock web content)
- [ ] Integration tests (real navigation)

### Phase 5: CI/CD ✅
- [x] GitHub Actions workflow
- [x] Self-hosted Mac mini runner
- [x] Run on all PRs to main
- [x] Test both iOS and macOS targets

---

## API Design

### BrowserEngine

```swift
@MainActor
public final class BrowserEngine: ObservableObject {
    // Navigation
    func navigate(to url: String) async throws -> NavigationResult
    func goBack() async throws -> NavigationResult
    func goForward() async throws -> NavigationResult
    func reload() async throws -> NavigationResult
    
    // Content
    func screenshot(fullPage: Bool) async throws -> Data
    func extractText() async throws -> String
    func extractHTML(selector: String?) async throws -> String
    func extractLinks() async throws -> [LinkInfo]
    func extractFormFields() async throws -> [FormFieldInfo]
    
    // Interaction
    func click(selector: String) async throws
    func clickText(_ text: String, tag: String?) async throws
    func fill(selector: String, text: String) async throws
    func type(selector: String, text: String, delay: Int) async throws
    func select(selector: String, value: String) async throws
    func scroll(_ direction: ScrollDirection, amount: Int) async throws
    
    // Waiting
    func waitForElement(selector: String, timeout: TimeInterval) async throws
    func waitForText(_ text: String, timeout: TimeInterval) async throws
    func waitForNavigation(timeout: TimeInterval) async throws
    
    // JavaScript
    func evaluateJavaScript(_ script: String) async throws -> Any?
}
```

### BrowserTool (LLM Schema)

```swift
public struct BrowserTool {
    public enum Action: String, CaseIterable {
        case navigate, goBack, goForward, reload
        case screenshot, extractText, extractHTML
        case extractLinks, extractForms
        case click, clickText, fill, type, clear
        case submit, select, setChecked
        case scroll, scrollTo, scrollToTop, scrollToBottom
        case waitForElement, waitForText, waitForNavigation
        case evaluate
    }
    
    public struct Parameters: Codable {
        let action: Action
        let url: String?
        let selector: String?
        let text: String?
        let script: String?
        let direction: String?
        let fullPage: Bool?
        // ... more optional params
    }
    
    public struct Result: Codable {
        let success: Bool
        let message: String?
        let data: String?
        let screenshot: Data?
        let links: [LinkResult]?
        let formFields: [FormFieldResult]?
        let error: String?
    }
    
    static var jsonSchema: [String: Any] // For LLM function calling
}
```

---

## Test Plan

### Unit Tests

1. **BrowserToolTests**
   - Action enum has all cases
   - Parameters encode/decode correctly
   - Result success/failure helpers
   - JSON schema structure

2. **BrowserTypesTests**
   - Configuration defaults
   - NavigationResult properties
   - ScrollDirection encoding
   - LinkInfo/FormFieldInfo structure

3. **BrowserErrorTests**
   - Error descriptions
   - User-friendly messages
   - Error case coverage

### Integration Tests

4. **BrowserEngineTests** (requires WebView)
   - Load local HTML
   - Extract text content
   - Click elements
   - Fill forms
   - Take screenshots

5. **BrowserToolExecutorTests**
   - Execute all action types
   - Handle errors gracefully
   - Auto-start behavior

---

## CI Configuration

```yaml
name: Tests
on:
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: [self-hosted, macOS, mac-mini]
    steps:
      - checkout
      - swift test (macOS)
      - xcodebuild test (iOS Simulator)
```

---

## Success Criteria

- [ ] All 30+ browser actions implemented
- [ ] iOS 16+ and macOS 13+ support
- [ ] 20+ unit tests passing
- [ ] CI runs on all PRs
- [ ] README with usage examples
- [ ] JSON schema works with LLMs
