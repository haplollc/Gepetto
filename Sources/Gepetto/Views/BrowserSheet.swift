//
//  BrowserSheet.swift
//  Gepetto
//
//  Presentable sheet for browser automation.
//

import SwiftUI

/// A sheet that presents the browser for AI automation.
public struct BrowserSheet: View {
    @ObservedObject var executor: BrowserToolExecutor
    @Environment(\.dismiss) private var dismiss
    
    /// Initial URL to load
    let initialURL: String?
    
    /// Title for the sheet
    let title: String?
    
    /// Called when the sheet is dismissed
    let onDismiss: (() -> Void)?
    
    /// Creates a browser sheet.
    /// - Parameters:
    ///   - executor: The tool executor
    ///   - initialURL: Optional URL to load on appear
    ///   - title: Optional title for the sheet
    ///   - onDismiss: Called when dismissed
    public init(
        executor: BrowserToolExecutor,
        initialURL: String? = nil,
        title: String? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.executor = executor
        self.initialURL = initialURL
        self.title = title
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        NavigationStack {
            Group {
                if let engine = executor.engine {
                    BrowserView(engine: engine)
                        .overlay(alignment: .top) {
                            BrowserAIIndicator(executor: executor)
                                .padding(.top, 8)
                        }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "safari")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Browser Not Ready")
                            .font(.headline)
                        Text("Starting browser...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        executor.start()
                    }
                }
            }
            .navigationTitle(title ?? executor.engine?.pageTitle ?? "Browser")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss?()
                        dismiss()
                    }
                    .tint(.primary)
                }
                
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let url = executor.engine?.currentURL {
                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            
                            Button {
                                UIPasteboard.general.url = url
                            } label: {
                                Label("Copy URL", systemImage: "doc.on.doc")
                            }
                        }
                        
                        Button(role: .destructive) {
                            executor.stop()
                            dismiss()
                        } label: {
                            Label("Close Browser", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                #endif
            }
        }
        .onAppear {
            if executor.engine == nil {
                executor.start()
            }
            
            if let url = initialURL {
                Task {
                    try? await executor.engine?.navigate(to: url)
                }
            }
        }
        .onDisappear {
            onDismiss?()
        }
    }
}

// MARK: - View Modifier

/// View modifier to present browser sheet.
public struct BrowserSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject var executor: BrowserToolExecutor
    let initialURL: String?
    let title: String?
    
    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                BrowserSheet(
                    executor: executor,
                    initialURL: initialURL,
                    title: title
                ) {
                    isPresented = false
                }
            }
    }
}

public extension View {
    /// Present a browser sheet.
    /// - Parameters:
    ///   - isPresented: Binding to control presentation
    ///   - executor: The browser tool executor
    ///   - initialURL: Optional URL to load
    ///   - title: Optional sheet title
    func browserSheet(
        isPresented: Binding<Bool>,
        executor: BrowserToolExecutor,
        initialURL: String? = nil,
        title: String? = nil
    ) -> some View {
        modifier(BrowserSheetModifier(
            isPresented: isPresented,
            executor: executor,
            initialURL: initialURL,
            title: title
        ))
    }
}

// MARK: - Full Screen Cover Modifier

/// View modifier to present browser as full screen cover.
public struct BrowserFullScreenModifier: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject var executor: BrowserToolExecutor
    let initialURL: String?
    let title: String?
    
    public func body(content: Content) -> some View {
        content
            #if os(iOS)
            .fullScreenCover(isPresented: $isPresented) {
                BrowserSheet(
                    executor: executor,
                    initialURL: initialURL,
                    title: title
                ) {
                    isPresented = false
                }
            }
            #else
            .sheet(isPresented: $isPresented) {
                BrowserSheet(
                    executor: executor,
                    initialURL: initialURL,
                    title: title
                ) {
                    isPresented = false
                }
                .frame(minWidth: 800, minHeight: 600)
            }
            #endif
    }
}

public extension View {
    /// Present a browser as full screen cover (iOS) or large sheet (macOS).
    func browserFullScreen(
        isPresented: Binding<Bool>,
        executor: BrowserToolExecutor,
        initialURL: String? = nil,
        title: String? = nil
    ) -> some View {
        modifier(BrowserFullScreenModifier(
            isPresented: isPresented,
            executor: executor,
            initialURL: initialURL,
            title: title
        ))
    }
}

// MARK: - Preview

#if swift(>=5.9)
@available(iOS 17.0, macOS 14.0, *)
#Preview {
    @Previewable @State var showBrowser = true
    let executor = BrowserToolExecutor()
    
    Text("Hello")
        .browserSheet(
            isPresented: $showBrowser,
            executor: executor,
            initialURL: "https://apple.com"
        )
}
#endif
