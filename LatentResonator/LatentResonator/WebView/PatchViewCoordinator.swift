import Foundation
import SwiftUI
import WebKit

// MARK: - WebView Wrapper (Suppresses Native Context Menu)

/// NSView wrapper that suppresses the native WKWebView context menu.
class NoContextMenuWebView: WKWebView {
    
    
    /// Override menuForEvent to suppress native context menu.
    /// Returns nil so the event passes through to JavaScript.
    override func menu(for event: NSEvent) -> NSMenu? {
        
        // Return nil to suppress the native menu
        return nil
    }
    
    /// Additional override for right-click events
    override func rightMouseDown(with event: NSEvent) {
        
        // Pass to superclass to trigger context menu event in JS
        super.rightMouseDown(with: event)
    }
}

// MARK: - UI Delegate (Handles JavaScript Dialogs)

/// WKUIDelegate to enable JavaScript alert() and confirm() dialogs.
/// Note: prompt() is disabled - use WebViewBridge message system for node control.
class PatchEditorUIDelegate: NSObject, WKUIDelegate {

    /// Handle JavaScript alert() calls
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Alert"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()
        }
    }
    
    /// Handle JavaScript confirm() calls
    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Confirm"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn)
        }
    }
}

// MARK: - Navigation Delegate (Debug)

class PatchNavigationDelegate: NSObject, WKNavigationDelegate {
    var onDidFinish: (() -> Void)?
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[PATCH DEBUG] Navigation finished")
        onDidFinish?()
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[PATCH DEBUG] Navigation failed: \(error.localizedDescription)")
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[PATCH DEBUG] Provisional navigation failed: \(error.localizedDescription)")
    }
}

// MARK: - Patch View Coordinator

/// Manages WKWebView lifecycle for the PATCH editor.
///
/// Responsibilities:
/// - Create WKWebView with bridge message handler
/// - Load bundled HTML/JS assets
/// - Configure security policy (local file access only)
/// - Handle view lifecycle
struct PatchViewCoordinator {
    
    let webView: NoContextMenuWebView
    let bridge: WebViewBridge
    let uiDelegate: PatchEditorUIDelegate
    let navigationDelegate: PatchNavigationDelegate
    
    
    // MARK: - Init

    init(nodeGraph: NodeGraph, aceBridge: ACEStepBridge? = nil) {
        let configuration = WKWebViewConfiguration()

        // Disable cache to prevent stale data
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        // Create bridge (PATCH view shows full graph - v2.0 flat architecture)
        let bridge = WebViewBridge()
        bridge.nodeGraph = nodeGraph
        bridge.aceBridge = aceBridge
        print("[PATCH DEBUG] Bridge created with nodeGraph and aceBridge")
        
        // Register message handler
        let contentController = WKUserContentController()
        contentController.add(bridge, name: "bridge")
        configuration.userContentController = contentController
        print("[PATCH DEBUG] Message handler registered with name 'bridge'")
        
        // Allow local file access (for bundled React Flow assets)
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        // Inject script to ensure context menu events reach React Flow and capture JS errors
        let debugScript = WKUserScript(
            source: """
            document.addEventListener('contextmenu', function(e) {
                console.log('[JS INJECTED] Context menu event');
            }, true);
            
            // CRITICAL: Capture all JS console logs and send to Swift
            const originalLog = console.log;
            const originalError = console.error;
            const originalWarn = console.warn;
            
            function sendToSwift(type, args) {
                try {
                    const message = args.map(a => {
                        try { return JSON.stringify(a); } catch(e) { return String(a); }
                    }).join(' ');
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                        window.webkit.messageHandlers.bridge.postMessage({
                            action: 'client.console',
                            type: type,
                            message: message.substring(0, 1000) // Limit size
                        });
                    }
                } catch(e) {}
            }
            
            console.log = function(...args) {
                originalLog.apply(console, args);
                sendToSwift('log', args);
            };
            
            console.error = function(...args) {
                originalError.apply(console, args);
                sendToSwift('error', args);
            };
            
            console.warn = function(...args) {
                originalWarn.apply(console, args);
                sendToSwift('warn', args);
            };
            
            // Capture unhandled errors
            window.addEventListener('error', function(e) {
                sendToSwift('error', ['Uncaught error:', e.message, 'at', e.filename + ':' + e.lineno]);
            });
            
            // Capture unhandled promise rejections
            window.addEventListener('unhandledrejection', function(e) {
                sendToSwift('error', ['Unhandled promise rejection:', e.reason]);
            });
            
            // DEBUG: Log all messages from Swift
            const originalHandler = window.receiveBridgeMessage;
            window.receiveBridgeMessage = function(message) {
                console.log('[JS INJECTED] Swift → JS:', message.event, message);
                if (originalHandler) {
                    originalHandler(message);
                } else {
                    console.error('[JS INJECTED] ERROR: bridge.ts not loaded yet!');
                }
            };
            
            console.log('[JS INJECTED] Bridge interceptor and console capture active');
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(debugScript)
        
        // Create web view with custom class that suppresses native menu
        let webView = NoContextMenuWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        
        // Create and set UI delegate to enable JavaScript dialogs (prompt, alert, confirm)
        let uiDelegate = PatchEditorUIDelegate()
        webView.uiDelegate = uiDelegate
        
        // Create and set navigation delegate to track load events
        let navigationDelegate = PatchNavigationDelegate()
        webView.navigationDelegate = navigationDelegate
        
        // Link bridge to webview
        bridge.webView = webView
        
        self.webView = webView
        self.bridge = bridge
        self.uiDelegate = uiDelegate
        self.navigationDelegate = navigationDelegate
    }
    
    // MARK: - Load Assets
    
    /// Load the bundled React Flow app.
    /// Looks for dist/index.html in the app bundle.
    func loadPatchEditor() {
        // Try multiple paths to locate the dist folder
        var bundleURL: URL?

        // Path 1: Look for index.html in PatchEditor/dist (Resources/PatchEditor/dist/index.html)
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "PatchEditor/dist") {
            bundleURL = url
            print("PatchViewCoordinator: Found bundle at \(url.path)")
        }
        // Path 2: Direct path in PatchEditor folder (alternative format)
        else if let url = Bundle.main.url(forResource: "PatchEditor/dist/index", withExtension: "html") {
            bundleURL = url
            print("PatchViewCoordinator: Found bundle at \(url.path)")
        }
        // Path 3: Build products directory (for development)
        else if let resourcePath = Bundle.main.resourcePath {
            let devPath = URL(fileURLWithPath: resourcePath).appendingPathComponent("PatchEditor/dist/index.html")
            if FileManager.default.fileExists(atPath: devPath.path) {
                bundleURL = devPath
                print("PatchViewCoordinator: Found bundle at \(devPath.path)")
            }
        }
        
        guard let finalURL = bundleURL else {
            print("PatchViewCoordinator: PatchEditor bundle not found in any location")
            print("PatchViewCoordinator: Bundle resource path = \(Bundle.main.resourcePath ?? "nil")")            
            // Fallback: show placeholder
            let placeholder = """
            <html>
            <head>
                <style>
                    body { 
                        margin: 0; 
                        background: #0a0b0c; 
                        color: #eaeaea; 
                        font-family: 'Fira Code', monospace; 
                        display: flex; 
                        align-items: center; 
                        justify-content: center; 
                        height: 100vh;
                        text-align: center;
                    }
                    .container { max-width: 600px; }
                    h1 { color: #00ccff; margin-bottom: 20px; }
                    code { background: #1a1b1c; padding: 4px 8px; border-radius: 3px; }
                </style>
            </head>
            <body>
                <div class="container">
                    <h1>PATCH EDITOR</h1>
                    <p>Build the React Flow app to enable the node editor.</p>
                    <code>cd PatchEditor && npm install && npm run build</code>
                </div>
            </body>
            </html>
            """
            
            webView.loadHTMLString(placeholder, baseURL: nil)
            return
        }
        
        print("[PATCH DEBUG] Loading from \(finalURL.path)")
        
        // Allow read access to the dist folder and its parent (Resources)
        let distFolder = finalURL.deletingLastPathComponent()        
        webView.loadFileURL(finalURL, allowingReadAccessTo: distFolder)
        
        print("[PATCH DEBUG] WebView loading started")
        
        // Set navigation delegate to track loading
        self.navigationDelegate.onDidFinish = {
            print("[PATCH DEBUG] WebView finished loading")
            // Bridge is ready - JS will receive confirmation on next sync
        }
    }
    
    // MARK: - Telemetry Timer
    
    /// Start telemetry broadcast at ~15Hz.
    func startTelemetry() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
            self.bridge.sendTelemetry()
        }
    }

    /// Start bridge status updates to JS at ~1Hz (slower, less critical than telemetry).
    func startBridgeStatusUpdates() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.bridge.sendBridgeStatusToJS()
        }
    }
}

// MARK: - SwiftUI Wrapper

/// SwiftUI view wrapping the WKWebView for PATCH mode.
struct PatchEditorView: NSViewRepresentable {

    @ObservedObject var nodeGraph: NodeGraph
    var aceBridge: ACEStepBridge?

    func makeNSView(context: Context) -> NoContextMenuWebView {
        let coordinator = PatchViewCoordinator(nodeGraph: nodeGraph, aceBridge: aceBridge)
        context.coordinator.coordinator = coordinator

        coordinator.loadPatchEditor()
        coordinator.startTelemetry()
        coordinator.startBridgeStatusUpdates()

        // Send initial graph state to JS (v2.0: full flat graph)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            coordinator.bridge.sendFullGraphToJS()
        }

        return coordinator.webView
    }
    
    func updateNSView(_ nsView: NoContextMenuWebView, context: Context) {
        // PATCH_DEBUG: Log view updates to detect excessive refresh cycles
        let updateLog: [String: Any] = [
            "id": "patch_update_\(Int(Date().timeIntervalSince1970 * 1000))",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "location": "PatchViewCoordinator.swift:updateNSView",
            "message": "View update triggered",
            "data": [:],
            "sessionId": "7175df",
            "hypothesisId": "PATCH_CHAOS"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: updateLog),
           let jsonStr = String(data: data, encoding: .utf8) {
            let logPath = "/Users/leolambertini/RLTNAS/.cursor/debug-7175df.log"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write((jsonStr + "\n").data(using: .utf8)!)
                handle.closeFile()
            }
        }

        // v2.0: Send full graph (flat architecture - no lane filtering needed)
        // Avoid excessive updates by checking if graph has actually changed
        context.coordinator.coordinator?.bridge.sendFullGraphToJS()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var coordinator: PatchViewCoordinator?
    }
}
