import Foundation
import WebKit
import Combine

// MARK: - WebView Bridge

/// Bidirectional Swift ↔ JavaScript bridge for PATCH view communication.
///
/// Protocol: JSON messages with action/data structure.
/// Thread safety: All messages processed on main thread.
///
/// Message flow:
/// - Swift → JS: sendToJS(event:data:) → window.webkit.messageHandlers callback
/// - JS → Swift: window.webkit.messageHandlers.bridge.postMessage() → userContentController
final class WebViewBridge: NSObject, WKScriptMessageHandler {

    // MARK: - Dependencies

    weak var nodeGraph: NodeGraph?
    weak var webView: WKWebView?

    // MARK: - Message Handler (JS → Swift)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let receiveTime = Date()
        print("[PATCH DEBUG] Received message from JS: \(message.body)")
        
        guard let body = message.body as? [String: Any] else {
            print("[PATCH DEBUG] ERROR: invalid message format")
            return
        }

        guard let action = body["action"] as? String else {
            print("[PATCH DEBUG] ERROR: missing action field")
            return
        }
        
        print("[PATCH DEBUG] Action received: \(action)")

        handleMessage(action: action, data: body)
        
        let processingTime = Date().timeIntervalSince(receiveTime) * 1000
        if processingTime > 16 { // Log slow processing (>1 frame at 60fps)
            print("[PATCH DEBUG] ⚠️ Slow message processing: \(String(format: "%.2f", processingTime))ms for action '\(action)'")
        }
    }

    private func handleMessage(action: String, data: [String: Any]) {
        switch action {
        // Graph mutations
        case "graph.addNode":
            handleAddNode(data)
        case "graph.removeNode":
            handleRemoveNode(data)
        case "graph.updateNodePosition":
            handleUpdateNodePosition(data)
        case "graph.connectEdge":
            handleConnectEdge(data)
        case "graph.disconnectEdge":
            handleDisconnectEdge(data)
        case "graph.setParameter":
            handleSetParameter(data)

        // Exposed controls
        case "expose.add":
            handleExposeAdd(data)
        case "expose.remove":
            handleExposeRemove(data)

        // Macro bindings
        case "macro.addBinding":
            handleAddMacroBinding(data)

        // Macro-node operations
        case "macro.encapsulate":
            handleEncapsulate(data)
        case "macro.expand":
            handleExpand(data)

        // Viewport sync
        case "viewport.update":
            handleViewportUpdate(data)

        // Query
        case "graph.requestSync":
            sendFullGraphToJS()

        // Latency measurement (Phase 6)
        case "bridge.pong":
            handleLatencyPong(data)

        // Client console logging - captures JS console.log/error/warn
        case "client.console":
            if let type = data["type"] as? String, let message = data["message"] as? String {
                let prefix = "[JS CONSOLE]"
                switch type {
                case "error":
                    print("\(prefix) 🔴 ERROR: \(message)")
                case "warn":
                    print("\(prefix) ⚠️  WARN: \(message)")
                default:
                    print("\(prefix) \(message)")
                }
            }

        // Bridge status query
        case "bridge.getStatus":
            sendBridgeStatusToJS()

        default:
            print("WebViewBridge: unknown action '\(action)'")
        }
    }

    // MARK: - Mutation Handlers

    private func handleAddNode(_ data: [String: Any]) {
        print("[PATCH DEBUG] handleAddNode called with data: \(data)")
        
        guard let nodeType = data["nodeType"] as? String else {
            print("[PATCH DEBUG] ERROR: missing nodeType")
            sendToJS(event: "graph.error", data: ["error": "Missing nodeType"])
            return
        }
        guard let idString = data["id"] as? String else {
            print("[PATCH DEBUG] ERROR: missing id")
            sendToJS(event: "graph.error", data: ["error": "Missing id"])
            return
        }
        guard let id = UUID(uuidString: idString) else {
            print("[PATCH DEBUG] ERROR: invalid UUID: \(idString)")
            sendToJS(event: "graph.error", data: ["error": "Invalid UUID"])
            return
        }

        let params = data["params"] as? [String: Any] ?? [:]
        let position = extractPosition(from: data) ?? .zero
        
        print("[PATCH DEBUG] Adding node: type=\(nodeType), id=\(id.uuidString), pos=(\(position.x), \(position.y))")
        print("[PATCH DEBUG] nodeGraph is nil: \(nodeGraph == nil)")

        let mutation = GraphMutation.addNode(
            id: id,
            nodeType: nodeType,
            position: position,
            params: params
        )

        do {
            try nodeGraph?.applyMutation(mutation)
            print("[PATCH DEBUG] Node added successfully!")
            sendToJS(event: "graph.nodeAdded", data: ["id": id.uuidString, "success": true])
        } catch {
            print("[PATCH DEBUG] FAILED to add node: \(error.localizedDescription)")
            sendToJS(event: "graph.error", data: ["error": error.localizedDescription])
        }
    }

    private func handleRemoveNode(_ data: [String: Any]) {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString) else { return }

        let mutation = GraphMutation.removeNode(id: id)

        do {
            try nodeGraph?.applyMutation(mutation)
            sendToJS(event: "graph.nodeRemoved", data: ["id": id.uuidString, "success": true])
        } catch {
            sendToJS(event: "graph.error", data: ["error": error.localizedDescription])
        }
    }

    private var positionUpdateCount = 0
    private var lastPositionUpdateTime = Date()
    
    private func handleUpdateNodePosition(_ data: [String: Any]) {
        let startTime = Date()
        positionUpdateCount += 1
        
        guard let idString = data["nodeId"] as? String,
              let id = UUID(uuidString: idString),
              let x = data["x"] as? Double,
              let y = data["y"] as? Double else {
            print("[PATCH DEBUG] handleUpdateNodePosition: INVALID DATA")
            return
        }
        
        let timeSinceLast = Date().timeIntervalSince(lastPositionUpdateTime) * 1000
        lastPositionUpdateTime = Date()
        
        // Log every 10th update to avoid spam
        if positionUpdateCount % 10 == 0 {
            print("[PATCH DEBUG] handleUpdateNodePosition #\(positionUpdateCount): \(idString) at (\(String(format: "%.1f", x)), \(String(format: "%.1f", y))), delta: \(String(format: "%.1f", timeSinceLast))ms")
        }

        // CRITICAL: Use centralized position update for all nodes in flat graph
        nodeGraph?.setNodePosition(id: id, x: x, y: y)
        
        let processingTime = Date().timeIntervalSince(startTime) * 1000
        if processingTime > 8 { // Log slow updates (>0.5 frame at 60fps)
            print("[PATCH DEBUG] ⚠️ Slow position update: \(String(format: "%.2f", processingTime))ms for node \(idString)")
        }
    }

    private func handleConnectEdge(_ data: [String: Any]) {
        guard let sourceNodeId = UUID(uuidString: data["sourceNodeId"] as? String ?? ""),
              let targetNodeId = UUID(uuidString: data["targetNodeId"] as? String ?? ""),
              let sourcePortId = data["sourcePortId"] as? String,
              let targetPortId = data["targetPortId"] as? String,
              let signalTypeRaw = data["signalType"] as? String,
              let signalType = SignalType(rawValue: signalTypeRaw) else {
            sendToJS(event: "graph.error", data: ["error": "Invalid edge data"])
            return
        }

        let edge = GraphEdge(
            sourceNodeId: sourceNodeId,
            sourcePortId: sourcePortId,
            targetNodeId: targetNodeId,
            targetPortId: targetPortId,
            signalType: signalType
        )

        let mutation = GraphMutation.connectEdge(edge: edge)

        do {
            try nodeGraph?.applyMutation(mutation)
            sendToJS(event: "graph.edgeConnected", data: [
                "edgeId": edge.id.uuidString,
                "success": true
            ])
        } catch {
            sendToJS(event: "graph.error", data: ["error": error.localizedDescription])
        }
    }

    private func handleDisconnectEdge(_ data: [String: Any]) {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString) else { return }

        let mutation = GraphMutation.disconnectEdge(id: id)

        do {
            try nodeGraph?.applyMutation(mutation)
            sendToJS(event: "graph.edgeDisconnected", data: ["id": id.uuidString, "success": true])
        } catch {
            sendToJS(event: "graph.error", data: ["error": error.localizedDescription])
        }
    }

    private var setParameterCallCount = 0

    private func handleSetParameter(_ data: [String: Any]) {
        setParameterCallCount += 1

        guard let nodeIdString = data["nodeId"] as? String,
              let nodeId = UUID(uuidString: nodeIdString),
              let paramId = data["paramId"] as? String,
              let value = data["value"] else {
            // #region agent log - H3 UI sticky trace
            debugLogToAgent(location: "WebViewBridge:handleSetParameter", message: "Missing required params", data: [
                "hasNodeId": String(data["nodeId"] != nil),
                "hasParamId": String(data["paramId"] != nil),
                "hasValue": String(data["value"] != nil)
            ], hypothesisId: "H3")
            // #endregion
            return
        }

        // #region agent log - H3 UI parameter trace
        debugLogToAgent(location: "WebViewBridge:handleSetParameter", message: "Parameter update received", data: [
            "callCount": String(setParameterCallCount),
            "nodeId": nodeIdString,
            "paramId": paramId,
            "valueType": String(describing: type(of: value))
        ], hypothesisId: "H3")
        // #endregion

        let mutation = GraphMutation.setParameter(
            nodeId: nodeId,
            paramId: paramId,
            value: value
        )

        do {
            try nodeGraph?.applyMutation(mutation)

            // #region agent log - H3 UI success trace
            debugLogToAgent(location: "WebViewBridge:handleSetParameter", message: "Parameter applied successfully", data: [
                "nodeId": nodeIdString,
                "paramId": paramId
            ], hypothesisId: "H3")
            // #endregion

            sendToJS(event: "graph.parameterSet", data: [
                "nodeId": nodeId.uuidString,
                "paramId": paramId,
                "success": true
            ])
        } catch {
            // #region agent log - H3 UI error trace
            debugLogToAgent(location: "WebViewBridge:handleSetParameter", message: "Parameter application failed", data: [
                "nodeId": nodeIdString,
                "paramId": paramId,
                "error": error.localizedDescription
            ], hypothesisId: "H3")
            // #endregion
            sendToJS(event: "graph.error", data: ["error": error.localizedDescription])
        }
    }

    // MARK: - Exposed Control Handlers

    private func handleExposeAdd(_ data: [String: Any]) {
        guard let nodeIdString = data["nodeId"] as? String,
              let nodeId = UUID(uuidString: nodeIdString),
              let paramId = data["paramId"] as? String else { return }

        let control = ExposedControl(
            id: UUID(),
            nodeId: nodeId,
            paramId: paramId,
            label: data["displayName"] as? String ?? paramId,
            controlType: .knob,
            range: 0.0...1.0,
            defaultValue: 0.5,
            position: nodeGraph?.exposedControls.count ?? 0
        )

        nodeGraph?.addExposedControl(control)
        sendToJS(event: "graph.controlExposed", data: ["id": control.id.uuidString, "success": true])

        // Sync to client with updated exposed controls list (Phase 3)
        sendFullGraphToJS()
    }

    private func handleExposeRemove(_ data: [String: Any]) {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString) else { return }

        nodeGraph?.removeExposedControl(id: id)
        sendToJS(event: "graph.controlRemoved", data: ["id": id.uuidString, "success": true])
    }

    // MARK: - Macro Binding Handlers

    private func handleAddMacroBinding(_ data: [String: Any]) {
        guard let exposedControlIdString = data["exposedControlId"] as? String,
              let exposedControlId = UUID(uuidString: exposedControlIdString),
              let targetsData = data["targets"] as? [[String: Any]] else { return }

        let targets = targetsData.compactMap { targetData -> MacroTarget? in
            guard let nodeIdString = targetData["nodeId"] as? String,
                  let nodeId = UUID(uuidString: nodeIdString),
                  let paramId = targetData["paramId"] as? String,
                  let inputMin = targetData["inputMin"] as? Float,
                  let inputMax = targetData["inputMax"] as? Float,
                  let outputMin = targetData["outputMin"] as? Float,
                  let outputMax = targetData["outputMax"] as? Float else { return nil }

            return MacroTarget(
                nodeId: nodeId,
                paramId: paramId,
                inputRange: inputMin...inputMax,
                outputRange: outputMin...outputMax,
                curve: .linear
            )
        }

        let binding = MacroBinding(
            id: UUID(),
            exposedControlId: exposedControlId,
            targets: targets
        )

        nodeGraph?.addMacroBinding(binding)
        sendToJS(event: "graph.bindingAdded", data: ["id": binding.id.uuidString, "success": true])
    }

    // MARK: - Macro Node Handlers

    private func handleEncapsulate(_ data: [String: Any]) {
        guard let nodeIdsData = data["nodeIds"] as? [String],
              let name = data["name"] as? String else { return }

        let nodeIds = Set(nodeIdsData.compactMap { UUID(uuidString: $0) })

        do {
            let macroNode = try nodeGraph?.encapsulate(nodeIds: nodeIds, name: name)
            sendToJS(event: "graph.macroCreated", data: [
                "id": macroNode?.id.uuidString ?? "",
                "success": true
            ])
            sendFullGraphToJS()
        } catch {
            sendToJS(event: "graph.error", data: ["error": error.localizedDescription])
        }
    }

    private func handleExpand(_ data: [String: Any]) {
        guard let macroIdString = data["macroId"] as? String,
              let macroId = UUID(uuidString: macroIdString) else { return }

        do {
            try nodeGraph?.expand(macroId: macroId)
            sendToJS(event: "graph.macroExpanded", data: [
                "id": macroIdString,
                "success": true
            ])
            sendFullGraphToJS()
        } catch {
            sendToJS(event: "graph.error", data: ["error": error.localizedDescription])
        }
    }

    // MARK: - Viewport Handlers

    private func handleViewportUpdate(_ data: [String: Any]) {
        guard let x = data["x"] as? Float,
              let y = data["y"] as? Float,
              let zoom = data["zoom"] as? Float else { return }

        nodeGraph?.viewport.x = x
        nodeGraph?.viewport.y = y
        nodeGraph?.viewport.zoom = zoom
    }

    // MARK: - Swift → JS Communication

    /// Send message from Swift to JavaScript.
    private func sendToJS(event: String, data: [String: Any]) {
        print("[PATCH DEBUG] sendToJS called with event: \(event)")
        
        let payload: [String: Any] = [
            "event": event,
            "data": data,
            "timestamp": Date().timeIntervalSince1970
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[PATCH DEBUG] ERROR: Failed to serialize message")
            return
        }

        // CRITICAL FIX: Use receiveBridgeMessage which is what JS expects
        // The JS expects: { event: string, data: any, timestamp: number }
        let js = "window.receiveBridgeMessage && window.receiveBridgeMessage(\(jsonString))"

        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("[PATCH DEBUG] JS evaluation error: \(error)")
                } else {
                    print("[PATCH DEBUG] JS message sent successfully")
                }
            }
        }
    }

    /// Send complete graph state to JS (for initial load or after major changes).
    /// v2.0: Uses flat graph structure - all nodes in nodeGraph.nodes, all edges in nodeGraph.edges.
    func sendFullGraphToJS() {
        guard let graph = nodeGraph else { return }

        // v2.0: Flat graph - all nodes are in graph.nodes
        let allNodes = Array(graph.nodes.values)

        // Map nodes to data with auto-layout if needed
        let nodesData: [[String: Any]] = allNodes.enumerated().map { (index, node) in
            // Auto-layout: distribute nodes in a grid if they're at default position
            var x = node.x
            var y = node.y
            let isDefaultPosition = (x == 50.0 && y == 500.0) || (x == 0 && y == 0)

            if isDefaultPosition {
                // Grid layout: 5 columns, spaced 200 apart
                let col = index % 5
                let row = index / 5
                x = 100 + Double(col) * 250
                y = 100 + Double(row) * 150
            }

            return [
                "id": node.id.uuidString,
                "type": node.nodeType,
                "displayName": node.name,
                "category": node.category.rawValue,
                "x": x,
                "y": y,
                "ports": node.ports.map { [
                    "id": $0.id,
                    "label": $0.label,
                    "signalType": $0.signalType.rawValue,
                    "direction": $0.direction.rawValue
                ]},
                "parameters": serializeParameters(node.parameters)
            ]
        }

        // v2.0: Flat graph - all edges are in graph.edges
        let edgesData: [[String: Any]] = graph.edges.values.map { edge in
            [
                "id": edge.id.uuidString,
                "sourceNodeId": edge.sourceNodeId.uuidString,
                "sourcePortId": edge.sourcePortId,
                "targetNodeId": edge.targetNodeId.uuidString,
                "targetPortId": edge.targetPortId,
                "signalType": edge.signalType.rawValue
            ]
        }

        // Serialize exposed controls (Phase 3)
        let exposedControlsData: [[String: Any]] = graph.exposedControls.map { control in
            [
                "id": control.id.uuidString,
                "nodeId": control.nodeId.uuidString,
                "paramId": control.paramId,
                "displayName": control.label,
                "range": [control.range.lowerBound, control.range.upperBound]
            ]
        }

        // Send to JS
        sendToJS(event: "graph.sync", data: [
            "nodes": nodesData,
            "edges": edgesData,
            "exposedControls": exposedControlsData,
            "viewport": [
                "x": graph.viewport.x,
                "y": graph.viewport.y,
                "zoom": graph.viewport.zoom
            ]
        ])
    }

    // MARK: - Helpers

    private func serializeParameters(_ params: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]

        for (key, value) in params {
            if let v = value as? Float {
                result[key] = v
            } else if let v = value as? Int {
                result[key] = v
            } else if let v = value as? String {
                result[key] = v
            } else if let v = value as? Bool {
                result[key] = v
            } else if let v = value as? ExcitationMode {
                result[key] = v.rawValue
            } else if let v = value as? FilterMode {
                result[key] = v.rawValue
            } else if let v = value as? SaturationMode {
                result[key] = v.rawValue
            }
        }

        return result
    }

    private func extractPosition(from data: [String: Any]) -> CGPoint? {
        guard let x = data["x"] as? CGFloat,
              let y = data["y"] as? CGFloat else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Latency Measurement (Phase 6)

    func measureRoundTripLatency() {
        let startTime = Date()
        let pingId = UUID().uuidString

        // Send ping to JS
        sendToJS(event: "bridge.ping", data: ["id": pingId])

        // JS will respond with bridge.pong, measured in handleMessage
        self.latencyPingStart = (pingId, startTime)
    }

    private var latencyPingStart: (String, Date)?

    private func handleLatencyPong(_ data: [String: Any]) {
        guard let pingId = data["pingId"] as? String,
              let startInfo = latencyPingStart,
              startInfo.0 == pingId else { return }

        let latencyMs = Date().timeIntervalSince(startInfo.1) * 1000
        print("WebViewBridge: round-trip latency = \(String(format: "%.2f", latencyMs))ms")

        if latencyMs > 5.0 {
            print("WebViewBridge: WARNING - latency exceeds 5ms target")
        }

        latencyPingStart = nil
    }

    // MARK: - Telemetry

    /// Send telemetry data to JS (node values, levels, etc.)
    func sendTelemetry() {
        guard let graph = nodeGraph else { return }

        // Collect node values for visualization
        let telemetryData: [[String: Any]] = graph.nodes.values.map { node in
            var values: [String: Any] = [:]

            // Extract parameter values
            for (key, value) in node.parameters {
                if let num = value as? Float {
                    values[key] = num
                } else if let num = value as? Double {
                    values[key] = Float(num)
                }
            }

            return [
                "id": node.id.uuidString,
                "type": node.nodeType,
                "values": values
            ]
        }

        sendToJS(event: "telemetry.update", data: ["nodes": telemetryData])
    }

    // MARK: - Bridge Status

    /// Weak reference to the ACEStepBridge for status reporting
    weak var aceBridge: ACEStepBridge?

    /// Send bridge connection status to JS for UI overlay
    func sendBridgeStatusToJS() {
        guard let bridge = aceBridge else {
            sendToJS(event: "bridge.status", data: [
                "status": "DISCONNECTED",
                "isModelLoaded": false,
                "remoteDevice": "none",
                "remoteModelType": "none",
                "lastError": "Bridge not initialized",
                "consecutiveFailures": 0,
                "remoteInferenceCount": 0
            ])
            return
        }

        sendToJS(event: "bridge.status", data: [
            "status": bridge.status.rawValue,
            "isModelLoaded": bridge.isModelLoaded,
            "remoteDevice": bridge.remoteDevice,
            "remoteModelType": bridge.remoteModelType,
            "lastError": bridge.lastError ?? "",
            "consecutiveFailures": bridge.consecutiveFailures,
            "remoteInferenceCount": bridge.remoteInferenceCount
        ])
    }

    // MARK: - Debug Logging (Agent Instrumentation)

    /// Writes structured debug logs to the agent's log file for hypothesis testing.
    private func debugLogToAgent(location: String, message: String, data: [String: String], hypothesisId: String) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let logEntry: [String: Any] = [
            "sessionId": "54ee48",
            "id": "log_\(timestamp)_\(UUID().uuidString.prefix(8))",
            "timestamp": timestamp,
            "location": location,
            "message": message,
            "data": data,
            "hypothesisId": hypothesisId
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: logEntry),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let logPath = "/Users/leolambertini/RLTNAS/.cursor/debug-54ee48.log"
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write((jsonString + "\n").data(using: .utf8)!)
                    handle.closeFile()
                }
            } else {
                try? jsonString.write(toFile: logPath, atomically: false, encoding: .utf8)
            }
        }
    }
}
