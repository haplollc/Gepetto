//
//  Gepetto.swift
//  Gepetto
//
//  iOS/macOS browser automation for AI agents.
//
//  Gepetto provides programmatic control over a WKWebView-based browser,
//  enabling AI agents to navigate the web, fill forms, click elements,
//  take screenshots, and extract content.
//
//  ## Quick Start
//
//  ```swift
//  import Gepetto
//
//  // Create an executor for AI tool calls
//  let executor = BrowserToolExecutor()
//
//  // Navigate to a page
//  let result = await executor.execute(
//      BrowserTool.Parameters(action: .navigate, url: "https://example.com")
//  )
//
//  // Take a screenshot
//  let screenshot = await executor.execute(
//      BrowserTool.Parameters(action: .screenshot, fullPage: true)
//  )
//
//  // Fill a form
//  await executor.execute(
//      BrowserTool.Parameters(action: .fill, selector: "#email", text: "user@example.com")
//  )
//  ```
//
//  ## SwiftUI Integration
//
//  ```swift
//  struct MyView: View {
//      @StateObject var executor = BrowserToolExecutor()
//      @State var showBrowser = false
//
//      var body: some View {
//          Button("Open Browser") { showBrowser = true }
//              .browserSheet(
//                  isPresented: $showBrowser,
//                  executor: executor,
//                  initialURL: "https://example.com"
//              )
//      }
//  }
//  ```
//

import Foundation

// MARK: - Version

/// Gepetto version
public let browserKitVersion = "1.0.0"

// All types are automatically exported since they're declared public in their respective files.
// Import Gepetto to access:
//
// Core Types:
// - BrowserEngine
// - BrowserConfiguration
// - BrowserError
// - NavigationResult
// - ScrollDirection
// - LinkInfo
// - FormFieldInfo
// - ElementInfo
// - BrowserState
//
// Tool Types:
// - BrowserTool
// - BrowserTool.Action
// - BrowserTool.Parameters
// - BrowserTool.Result
// - BrowserToolExecutor
//
// Views:
// - BrowserView
// - BrowserNavBar
// - BrowserSheet
// - BrowserLoadingOverlay
// - BrowserAIIndicator
