import { BridgeMessage, BridgeEvent, NodeTelemetry } from './types';

// Bridge client for Swift ↔ JS communication

class Bridge {
  private listeners: Map<string, Set<(data: any) => void>> = new Map();
  private telemetryCallbacks: Set<(telemetry: NodeTelemetry[]) => void> = new Set();
  
  constructor() {    
    // Register global callback for messages from Swift
    (window as any).receiveBridgeMessage = (message: BridgeEvent) => {
      this.handleEvent(message);
    };
    
    console.log('Bridge: initialized');
  }
  
  // Send message to Swift
  send(message: BridgeMessage) {
    console.log('[JS BRIDGE] Sending message:', JSON.stringify(message));
    
    if (!(window as any).webkit?.messageHandlers?.bridge) {
      console.error('[JS BRIDGE] ERROR: Swift message handler not available');
      console.error('[JS BRIDGE] window.webkit?.messageHandlers?.bridge =', (window as any).webkit?.messageHandlers?.bridge);
      return;
    }
    
    try {
      (window as any).webkit.messageHandlers.bridge.postMessage(message);
      console.log('[JS BRIDGE] Message sent successfully to Swift');
    } catch (error) {
      console.error('[JS BRIDGE] FAILED to send message:', error);
    }
  }
  
  // Listen for events from Swift
  on(event: string, callback: (data: any) => void) {
    if (!this.listeners.has(event)) {
      this.listeners.set(event, new Set());
    }
    this.listeners.get(event)!.add(callback);
  }
  
  off(event: string, callback: (data: any) => void) {
    this.listeners.get(event)?.delete(callback);
  }
  
  // Subscribe to telemetry updates
  onTelemetry(callback: (telemetry: NodeTelemetry[]) => void) {
    this.telemetryCallbacks.add(callback);
  }
  
  offTelemetry(callback: (telemetry: NodeTelemetry[]) => void) {
    this.telemetryCallbacks.delete(callback);
  }
  
  // Handle incoming events from Swift
  private handleEvent(message: BridgeEvent) {
    console.log('[JS BRIDGE] Received event from Swift:', message);
    
    const { event, data } = message;
    
    // Phase 6: Respond to ping immediately for latency measurement
    if (event === 'bridge.ping') {
      this.send({ action: 'bridge.pong', id: data.id });
      return;
    }
    
    if (event === 'telemetry.update') {
      const telemetry = data.nodes as NodeTelemetry[];
      this.telemetryCallbacks.forEach(cb => cb(telemetry));
      return;
    }
    
    // Notify listeners
    this.listeners.get(event)?.forEach(callback => callback(data));
  }
  
  // Request full graph sync from Swift
  requestSync() {
    this.send({ action: 'graph.requestSync' });
  }
  
  // Graph mutations
  addNode(nodeType: string, position: { x: number; y: number }, params: Record<string, any> = {}) {
    const id = crypto.randomUUID();
    
    console.log('[JS BRIDGE] addNode called:', { nodeType, id, position, params });
    
    this.send({
      action: 'graph.addNode',
      id,
      nodeType,
      x: position.x,
      y: position.y,
      params
    });
    
    console.log('[JS BRIDGE] addNode message sent to Swift');
    return id;
  }
  
  removeNode(id: string) {
    this.send({ action: 'graph.removeNode', id });
  }
  
  updateNodePosition(nodeId: string, x: number, y: number) {
    // Send position updates immediately - no throttling to prevent sticky behavior
    // React Flow handles local positioning smoothly, we just sync to Swift
    this.send({
      action: 'graph.updateNodePosition',
      nodeId,
      x,
      y
    });
  }
  
  connectEdge(
    sourceNodeId: string,
    sourcePortId: string,
    targetNodeId: string,
    targetPortId: string,
    signalType: string
  ) {
    this.send({
      action: 'graph.connectEdge',
      sourceNodeId,
      sourcePortId,
      targetNodeId,
      targetPortId,
      signalType
    });
  }
  
  disconnectEdge(id: string) {
    this.send({ action: 'graph.disconnectEdge', id });
  }
  
  private lastParamUpdateTime: number = 0;
  private paramUpdateThrottleMs: number = 16; // Throttle to ~60fps max
  private pendingParamUpdate: { nodeId: string; paramId: string; value: any } | null = null;
  private paramUpdateRafId: number | null = null;
  
  setParameter(nodeId: string, paramId: string, value: any) {
    const now = Date.now();
    const timeSinceLastUpdate = now - this.lastParamUpdateTime;

    // #region agent log - H3 UI throttling trace
    fetch('http://127.0.0.1:7350/ingest/e5ed72bf-beb2-4b75-a821-f1bb07c7bc0b',{
      method:'POST',
      headers:{'Content-Type':'application/json','X-Debug-Session-Id':'54ee48'},
      body:JSON.stringify({
        sessionId:'54ee48',
        location:'bridge.ts:setParameter:entry',
        message:'setParameter called',
        data:{nodeId,paramId,valueType:typeof value,timeSinceLastUpdate:String(timeSinceLastUpdate)},
        timestamp:Date.now(),
        hypothesisId:'H3'
      })
    }).catch(()=>{});
    // #endregion

    // Throttle parameter updates to ~60fps to prevent bridge flooding
    if (timeSinceLastUpdate < this.paramUpdateThrottleMs) {
      // Store pending value and schedule via RAF if not already scheduled
      this.pendingParamUpdate = { nodeId, paramId, value };

      // #region agent log - H3 UI throttled trace
      fetch('http://127.0.0.1:7350/ingest/e5ed72bf-beb2-4b75-a821-f1bb07c7bc0b',{
        method:'POST',
        headers:{'Content-Type':'application/json','X-Debug-Session-Id':'54ee48'},
        body:JSON.stringify({
          sessionId:'54ee48',
          location:'bridge.ts:setParameter:throttled',
          message:'Update throttled, queued for RAF',
          data:{nodeId,paramId,throttleMs:String(this.paramUpdateThrottleMs)},
          timestamp:Date.now(),
          hypothesisId:'H3'
        })
      }).catch(()=>{});
      // #endregion

      if (this.paramUpdateRafId === null) {
        this.paramUpdateRafId = requestAnimationFrame(() => {
          if (this.pendingParamUpdate) {
            const { nodeId, paramId, value } = this.pendingParamUpdate;

            // #region agent log - H3 UI RAF execute trace
            fetch('http://127.0.0.1:7350/ingest/e5ed72bf-beb2-4b75-a821-f1bb07c7bc0b',{
              method:'POST',
              headers:{'Content-Type':'application/json','X-Debug-Session-Id':'54ee48'},
              body:JSON.stringify({
                sessionId:'54ee48',
                location:'bridge.ts:setParameter:rafExecute',
                message:'RAF executing queued update',
                data:{nodeId,paramId},
                timestamp:Date.now(),
                hypothesisId:'H3'
              })
            }).catch(()=>{});
            // #endregion

            this.send({
              action: 'graph.setParameter',
              nodeId,
              paramId,
              value
            });
            this.lastParamUpdateTime = Date.now();
            this.pendingParamUpdate = null;
            this.paramUpdateRafId = null;
          }
        });
      }
      return;
    }

    // Direct update if enough time passed
    this.lastParamUpdateTime = now;
    this.send({
      action: 'graph.setParameter',
      nodeId,
      paramId,
      value
    });
  }
  
  // Exposed controls
  exposeParameter(nodeId: string, paramId: string, label: string, controlType: string = 'knob') {
    this.send({
      action: 'expose.add',
      nodeId,
      paramId,
      label,
      controlType
    });
  }
  
  unexposeControl(id: string) {
    this.send({
      action: 'expose.remove',
      id
    });
  }
  
  // Macro bindings
  addMacroBinding(exposedControlId: string, targets: Array<{
    nodeId: string;
    paramId: string;
    inputRange: { min: number; max: number };
    outputRange: { min: number; max: number };
    curve: string;
  }>) {
    this.send({
      action: 'macro.addBinding',
      exposedControlId,
      targets
    });
  }
  
  // Macro-node operations
  encapsulateNodes(nodeIds: string[], name: string) {
    this.send({
      action: 'macro.encapsulate',
      nodeIds,
      name
    });
  }
  
  expandMacro(macroId: string) {
    this.send({
      action: 'macro.expand',
      macroId
    });
  }
  
  // Viewport sync
  updateViewport(x: number, y: number, zoom: number) {
    this.send({
      action: 'viewport.update',
      x,
      y,
      zoom
    });
  }
}

export const bridge = new Bridge();
