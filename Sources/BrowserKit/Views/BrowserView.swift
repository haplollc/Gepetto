//
//  BrowserView.swift
//  BrowserKit
//
//  SwiftUI view that displays and controls the browser.
//

import SwiftUI
import WebKit

/// SwiftUI wrapper for the browser WebView.
public struct BrowserView: View {
    @ObservedObject var engine: BrowserEngine
    
    /// Whether to show the navigation bar
    let showNavBar: Bool
    
    /// Whether to show loading progress
    let showProgress: Bool
    
    /// Creates a browser view.
    /// - Parameters:
    ///   - engine: The browser engine to display
    ///   - showNavBar: Whether to show navigation controls
    ///   - showProgress: Whether to show loading progress bar
    public init(
        engine: BrowserEngine,
        showNavBar: Bool = true,
        showProgress: Bool = true
    ) {
        self.engine = engine
        self.showNavBar = showNavBar
        self.showProgress = showProgress
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            if showNavBar {
                BrowserNavBar(engine: engine)
            }
            
            if showProgress && engine.isLoading {
                ProgressView(value: engine.loadingProgress)
                    .progressViewStyle(.linear)
            }
            
            WebViewRepresentable(webView: engine.webView)
        }
    }
}

// MARK: - Navigation Bar

/// Navigation bar for the browser.
public struct BrowserNavBar: View {
    @ObservedObject var engine: BrowserEngine
    @State private var urlText: String = ""
    @FocusState private var isURLFocused: Bool
    
    public init(engine: BrowserEngine) {
        self.engine = engine
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // Back button
            Button {
                Task { try? await engine.goBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
            }
            .disabled(!engine.canGoBack)
            
            // Forward button
            Button {
                Task { try? await engine.goForward() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .medium))
            }
            .disabled(!engine.canGoForward)
            
            // URL bar
            HStack(spacing: 8) {
                if engine.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: isSecure ? "lock.fill" : "globe")
                        .font(.system(size: 12))
                        .foregroundColor(isSecure ? .green : .secondary)
                }
                
                TextField("Search or enter URL", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isURLFocused)
                    .onSubmit {
                        navigateToURL()
                    }
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                
                if !urlText.isEmpty && isURLFocused {
                    Button {
                        urlText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            #if os(iOS)
            .background(Color(.systemGray6))
            #else
            .background(Color(nsColor: .controlBackgroundColor))
            #endif
            .cornerRadius(10)
            
            // Reload/Stop button
            Button {
                if engine.isLoading {
                    engine.stopLoading()
                } else {
                    Task { try? await engine.reload() }
                }
            } label: {
                Image(systemName: engine.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #if os(iOS)
        .background(Color(.systemBackground))
        #else
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
        .onChange(of: engine.currentURL) { newURL in
            if !isURLFocused {
                urlText = newURL?.absoluteString ?? ""
            }
        }
        .onAppear {
            urlText = engine.currentURL?.absoluteString ?? ""
        }
    }
    
    private var isSecure: Bool {
        engine.currentURL?.scheme == "https"
    }
    
    private func navigateToURL() {
        let text = urlText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        
        Task {
            try? await engine.navigate(to: text)
            isURLFocused = false
        }
    }
}

// MARK: - WebView Representable

#if os(iOS)
struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    
    func makeUIView(context: Context) -> WKWebView {
        webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#elseif os(macOS)
struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    
    func makeNSView(context: Context) -> WKWebView {
        webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

// MARK: - Loading Overlay

/// Overlay shown while browser is loading.
public struct BrowserLoadingOverlay: View {
    @ObservedObject var engine: BrowserEngine
    
    public init(engine: BrowserEngine) {
        self.engine = engine
    }
    
    public var body: some View {
        if engine.isLoading {
            ZStack {
                Color.black.opacity(0.3)
                
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    
                    Text("Loading...")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    if let url = engine.currentURL?.host {
                        Text(url)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - AI Control Indicator

/// Indicator showing AI is controlling the browser.
public struct BrowserAIIndicator: View {
    @ObservedObject var executor: BrowserToolExecutor
    
    public init(executor: BrowserToolExecutor) {
        self.executor = executor
    }
    
    public var body: some View {
        if executor.isActive {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                
                Text("AI Browsing")
                    .font(.system(size: 12, weight: .medium))
                
                if let engine = executor.engine, engine.isExecutingAction {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
        }
    }
}

// MARK: - Previews

#Preview("Browser View") {
    BrowserView(engine: BrowserEngine())
}

#Preview("AI Indicator") {
    BrowserAIIndicator(executor: BrowserToolExecutor())
}
