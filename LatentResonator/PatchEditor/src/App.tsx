import { useCallback, useEffect, useState, useRef } from 'react';
import {
  ReactFlow,
  MiniMap,
  Controls,
  Background,
  Node,
  Edge,
  Connection,
  addEdge,
  useNodesState,
  useEdgesState,
  BackgroundVariant,
} from '@xyflow/react';
import '@xyflow/react/dist/base.css';
import { bridge } from './bridge';
import { GraphNodeData, GraphEdgeData, NodeTelemetry } from './types';
import { NodeMenu } from './components/NodeMenu';
import { NodeContextMenu, ContextMenuAction } from './components/NodeContextMenu';
import { ErrorBoundary } from './components/ErrorBoundary';
import { BridgeStatusOverlay } from './components/BridgeStatusOverlay';
import { OscillatorNode } from './nodes/OscillatorNode';
import { NoiseNode } from './nodes/NoiseNode';
import { MixerNode } from './nodes/MixerNode';
import { MasterOutputNode } from './nodes/MasterOutputNode';
import { PassthroughNode } from './nodes/PassthroughNode';
import { MacroNode } from './nodes/MacroNode';
import { FFTAnalysisNode } from './nodes/FFTAnalysisNode';
import { SemanticEQNode } from './nodes/SemanticEQNode';
import { SpectralSaturationNode } from './nodes/SpectralSaturationNode';
import { SpectralNoiseNode } from './nodes/SpectralNoiseNode';
import { SpectralMemoryNode } from './nodes/SpectralMemoryNode';
import { SpectralGranularityNode } from './nodes/SpectralGranularityNode';
import { SpectralFreezeNode } from './nodes/SpectralFreezeNode';
import { IFFTSynthesisNode } from './nodes/IFFTSynthesisNode';
import { LadderFilterNode } from './nodes/LadderFilterNode';
import { CombFilterNode } from './nodes/CombFilterNode';
import { TunableResonatorNode } from './nodes/TunableResonatorNode';
import { BitCrusherNode } from './nodes/BitCrusherNode';
import { WaveshaperNode } from './nodes/WaveshaperNode';
import { DelayLineNode } from './nodes/DelayLineNode';
import { ACEStepInferenceNode } from './nodes/ACEStepInferenceNode';
import { PromptEngineNode } from './nodes/PromptEngineNode';
import { FeedbackLoopNode } from './nodes/FeedbackLoopNode';
import { AgitationNode } from './nodes/AgitationNode';
import { PeakNode } from './nodes/PeakNode';
import { ManualControlNode } from './nodes/ManualControlNode';
import { StepSequencerNode } from './nodes/StepSequencerNode';
import { MarkovSequencerNode } from './nodes/MarkovSequencerNode';
import { SpectralAnalyzerNode } from './nodes/SpectralAnalyzerNode';

const nodeTypes = {
  oscillator: OscillatorNode,
  noise: NoiseNode,
  mixer: MixerNode,
  master_output: MasterOutputNode,
  passthrough: PassthroughNode,
  macro: MacroNode,
  fft_analysis: FFTAnalysisNode,
  semantic_eq: SemanticEQNode,
  spectral_saturation: SpectralSaturationNode,
  spectral_noise: SpectralNoiseNode,
  spectral_memory: SpectralMemoryNode,
  spectral_granularity: SpectralGranularityNode,
  spectral_freeze: SpectralFreezeNode,
  ifft_synthesis: IFFTSynthesisNode,
  ladder_filter: LadderFilterNode,
  comb_filter: CombFilterNode,
  tunable_resonator: TunableResonatorNode,
  bit_crusher: BitCrusherNode,
  waveshaper: WaveshaperNode,
  delay_line: DelayLineNode,
  ace_step_inference: ACEStepInferenceNode,
  prompt_engine: PromptEngineNode,
  feedback_loop: FeedbackLoopNode,
  agitation: AgitationNode,
  peak: PeakNode,
  manual_control: ManualControlNode,
  step_sequencer: StepSequencerNode,
  markov_sequencer: MarkovSequencerNode,
  spectral_analyzer: SpectralAnalyzerNode,
};

function App() {  
  const [nodes, setNodes, onNodesChangeInternal] = useNodesState<Node>([] as Node[]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge>([] as Edge[]);
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number } | null>(null);
  const [nodeContextMenu, setNodeContextMenu] = useState<{ x: number; y: number; node: Node } | null>(null);
  const [exposedControlsMap, setExposedControlsMap] = useState<Map<string, { id: string, label: string }>>(new Map());
  const [exposedControlsList, setExposedControlsList] = useState<Array<{ id: string, nodeId: string, paramId: string, label: string }>>([]);
  // Phase 5: Viewport sync removed - useReactFlow requires ReactFlowProvider wrapper
  
  // Intercept node changes to update positions in Swift
  const pendingPositionUpdatesRef = useRef<Map<string, {x: number, y: number}>>(new Map());
  const dragTimeoutRef = useRef<Map<string, number>>(new Map());

  const onNodesChange = useCallback((changes: any) => {
    onNodesChangeInternal(changes);
    
    // Update positions in Swift - optimized for smooth dragging
    changes.forEach((change: any) => {
      if (change.type === 'position' && change.position) {
        if (change.dragging === false) {
          // Drag ended - send final position immediately
          console.log('[DEBUG UI] Position change - drag ended for', change.id, 'at', change.position);
          bridge.updateNodePosition(change.id, change.position.x, change.position.y);
          pendingPositionUpdatesRef.current.delete(change.id);
          
          // Clear any pending timeout
          const existingTimeout = dragTimeoutRef.current.get(change.id);
          if (existingTimeout) {
            clearTimeout(existingTimeout);
            dragTimeoutRef.current.delete(change.id);
          }
        } else {
          // Still dragging - debounce the update for smooth performance
          pendingPositionUpdatesRef.current.set(change.id, {x: change.position.x, y: change.position.y});
          
          // Clear existing timeout and set new one
          const existingTimeout = dragTimeoutRef.current.get(change.id);
          if (existingTimeout) {
            clearTimeout(existingTimeout);
          }
          
          const timeoutId = window.setTimeout(() => {
            const pendingPos = pendingPositionUpdatesRef.current.get(change.id);
            if (pendingPos) {
              bridge.updateNodePosition(change.id, pendingPos.x, pendingPos.y);
              pendingPositionUpdatesRef.current.delete(change.id);
            }
            dragTimeoutRef.current.delete(change.id);
          }, 100); // 100ms debounce during drag for smooth sync
          
          dragTimeoutRef.current.set(change.id, timeoutId);
        }
      }
    });
  }, [onNodesChangeInternal]);

  
  // Subscribe to telemetry updates
  useEffect(() => {
    const handleTelemetry = (data: NodeTelemetry[]) => {
      // Update node data with telemetry
      setNodes((nds) =>
        nds.map((node) => {
          const tel = data.find(t => t.nodeId === node.id);
          if (tel) {
            return {
              ...node,
              data: {
                ...node.data,
                telemetry: tel,
              },
            };
          }
          return node;
        })
      );
    };
    
    bridge.onTelemetry(handleTelemetry);
    
    return () => {
      bridge.offTelemetry(handleTelemetry);
    };
  }, [setNodes]);

  useEffect(() => {    
    bridge.requestSync();
    
    const handleFullSync = (data: any) => {
      console.log('Received full graph sync', data);
      
      // #region agent log
      fetch('http://127.0.0.1:7243/ingest/e5ed72bf-beb2-4b75-a821-f1bb07c7bc0b',{method:'POST',headers:{'Content-Type':'application/json','X-Debug-Session-Id':'6e9afe'},body:JSON.stringify({sessionId:'6e9afe',location:'App.tsx:handleFullSync',message:'Received graph sync in React',data:{nodeCount:data.nodes?.length||0,edgeCount:data.edges?.length||0},timestamp:Date.now(),hypothesisId:'PATCH_JS'})}).catch(()=>{});
      // #endregion
      
      const reactFlowNodes: Node[] = (data.nodes || []).map((node: GraphNodeData) => ({
        id: node.id,
        type: node.type,
        position: { x: node.x || 100, y: node.y || 100 },
        data: {
          ...node,
          // Mark parameters that are exposed (green indicator)
          exposedParams: (data.exposedControls || [])
            .filter((c: any) => c.nodeId === node.id)
            .map((c: any) => c.paramId)
        },
      }));
      
      const reactFlowEdges: Edge[] = (data.edges || []).map((edge: GraphEdgeData) => ({
        id: edge.id,
        source: edge.sourceNodeId,
        sourceHandle: edge.sourcePortId,
        target: edge.targetNodeId,
        targetHandle: edge.targetPortId,
        type: edge.signalType === 'audio' ? 'default' : 'step',
        animated: edge.signalType === 'control',
      }));
      
      // Phase 4: Track exposed controls for macro binding UI
      const controlsMap = new Map<string, { id: string, label: string }>();
      const controlsList: Array<{ id: string, nodeId: string, paramId: string, label: string }> = [];
      (data.exposedControls || []).forEach((control: any) => {
        const key = `${control.nodeId}-${control.paramId}`;
        controlsMap.set(key, { id: control.id, label: control.label });
        controlsList.push({
          id: control.id,
          nodeId: control.nodeId,
          paramId: control.paramId,
          label: control.label
        });
      });
      setExposedControlsMap(controlsMap);
      setExposedControlsList(controlsList);
      
      setNodes(reactFlowNodes as any);
      setEdges(reactFlowEdges as any);      
      // Log exposed controls for debugging (Phase 3)
      if (data.exposedControls && data.exposedControls.length > 0) {
        console.log('Exposed controls synced:', data.exposedControls);
      }
      
      // Phase 5: Viewport sync disabled (would require ReactFlowProvider wrapper)
      // To enable: wrap App in ReactFlowProvider and use useReactFlow() hook
      
    };
    
    const handleNodeAdded = (data: any) => {
      console.log('[JS APP] handleNodeAdded called with data:', data);
      
      // Request full sync to get the new node's complete data
      bridge.requestSync();
    };
    
    // Phase 5: Sync edge IDs from Swift to React Flow
    const handleEdgeConnected = (data: any) => {
      const { edgeId, sourceNodeId, sourcePortId, targetNodeId, targetPortId } = data;
      
      // Find temporary edge in React Flow and replace with Swift-generated ID
      setEdges((eds: Edge[]) => {
        const tempEdge = eds.find(
          (e: Edge) =>
            e.source === sourceNodeId &&
            e.sourceHandle === sourcePortId &&
            e.target === targetNodeId &&
            e.targetHandle === targetPortId
        );
        
        if (tempEdge) {
          // Replace temporary edge with Swift ID
          return eds.map((e: Edge) => (e === tempEdge ? { ...e, id: edgeId } : e));
        }
        
        return eds;
      });
    };
    
    bridge.on('graph.sync', handleFullSync);
    bridge.on('graph.nodeAdded', handleNodeAdded);
    bridge.on('graph.edgeConnected', handleEdgeConnected);
    
    return () => {
      bridge.off('graph.sync', handleFullSync);
      bridge.off('graph.nodeAdded', handleNodeAdded);
      bridge.off('graph.edgeConnected', handleEdgeConnected);
    };
  }, [setNodes, setEdges]);

  const onConnect = useCallback(
    (connection: Connection) => {
      if (!connection.source || !connection.target) return;
      
      
      const sourceNode = nodes.find((n: Node) => n.id === connection.source);
      const nodeData = sourceNode?.data as GraphNodeData | undefined;
      const sourcePort = nodeData?.ports.find(
        (p) => p.id === connection.sourceHandle
      );
      const signalType = sourcePort?.signalType || 'audio';
      
      bridge.connectEdge(
        connection.source,
        connection.sourceHandle || 'out',
        connection.target,
        connection.targetHandle || 'in',
        signalType
      );
      
      setEdges((eds: any) =>
        addEdge(
          {
            ...connection,
            type: signalType === 'audio' ? 'default' : 'step',
            animated: signalType === 'control',
          },
          eds
        )
      );
    },
    [nodes, setEdges]
  );

  const onEdgesDelete = useCallback((edgesToDelete: Edge[]) => {
    
    edgesToDelete.forEach((edge: Edge) => {
      bridge.disconnectEdge(edge.id);
    });
  }, []);

  const onNodesDelete = useCallback((nodesToDelete: Node[]) => {
    
    nodesToDelete.forEach((node: Node) => {
      bridge.removeNode(node.id);
    });
  }, []);

  const onNodeContextMenu = useCallback(
    (event: React.MouseEvent, node: Node) => {
      event.preventDefault();
      setNodeContextMenu({ x: event.clientX, y: event.clientY, node });
    },
    []
  );

  const handleNodeContextAction = useCallback((action: ContextMenuAction) => {
    switch (action.type) {
      case 'expose':
        bridge.exposeParameter(action.nodeId, action.paramId, action.label, action.controlType);
        break;

      case 'hide':
        bridge.unexposeControl(action.controlId);
        break;

      case 'macro': {
        // Get exposed control ID from tracked map
        const controlKey = `${action.nodeId}-${action.sourceParamId}`;
        const controlData = exposedControlsMap.get(controlKey);
        if (!controlData) {
          console.error('Could not find exposed control ID for macro binding');
          return;
        }
        const targets = [{
          nodeId: action.targetNodeId,
          paramId: action.targetParamId,
          inputRange: { min: 0, max: 1 },
          outputRange: { min: 0, max: 1 },
          curve: action.curve
        }];
        bridge.addMacroBinding(controlData.id, targets);
        break;
      }

      case 'delete':
        bridge.removeNode(action.nodeId);
        setNodes((nds) => nds.filter((n) => n.id !== action.nodeId));
        break;

      case 'rename':
        // Send rename to Swift - Swift will broadcast back via graph sync
        console.log('Rename node:', action.nodeId, 'to', action.newName);
        // TODO: Add bridge.renameNode when Swift supports it
        break;

      case 'reset':
        // Reset node parameters to defaults
        console.log('Reset node to defaults:', action.nodeId);
        // TODO: Add bridge.resetNode when Swift supports it
        break;
    }
    setNodeContextMenu(null);
  }, [exposedControlsMap, setNodes]);

  const onPaneContextMenu = useCallback(
    (event: React.MouseEvent | MouseEvent) => {
      event.preventDefault();
      
      const clientX = 'clientX' in event ? event.clientX : 0;
      const clientY = 'clientY' in event ? event.clientY : 0;
      
      
      // Show visual node menu at click position
      setContextMenu({ x: clientX, y: clientY });
    },
    []
  );

  const handleNodeSelect = useCallback(
    (nodeType: string) => {
      console.log('[JS APP] handleNodeSelect called with nodeType:', nodeType);
      
      if (!contextMenu) {
        console.warn('[JS APP] No context menu available');
        return;
      }
      
      // Convert screen coordinates to React Flow canvas coordinates
      const reactFlowElement = document.querySelector('.react-flow');
      if (!reactFlowElement) {
        console.warn('[JS APP] React Flow element not found');
        setContextMenu(null);
        return;
      }
      
      const rect = reactFlowElement.getBoundingClientRect();
      const x = contextMenu.x - rect.left;
      const y = contextMenu.y - rect.top;
      
      console.log('[JS APP] Calling bridge.addNode at position:', { x, y });
      const nodeId = bridge.addNode(nodeType, { x, y });
      console.log('[JS APP] bridge.addNode returned id:', nodeId);
      
      setContextMenu(null);
    },
    [contextMenu]
  );

  const onNodeDoubleClick = useCallback(
    (_event: React.MouseEvent, node: Node) => {
      if (node.type === 'macro') {
        
        bridge.send({ action: 'macro.expand', macroId: node.id });
      }
    },
    []
  );

  // Debug handlers for sticky behavior - with detailed logging
  const dragStateRef = useRef<{ isDragging: boolean; nodeId: string | null; startTime: number }>({ 
    isDragging: false, 
    nodeId: null, 
    startTime: 0 
  });

  const onNodeClick = useCallback((_event: React.MouseEvent, node: Node) => {
    console.log('[DEBUG UI] Node clicked:', node.id, node.type);
  }, []);

  const onSelectionChange = useCallback(({ nodes: selectedNodes, edges: selectedEdges }: { nodes: Node[], edges: Edge[] }) => {
    console.log('[DEBUG UI] Selection changed:', selectedNodes.length, 'nodes,', selectedEdges.length, 'edges');
    if (selectedNodes.length > 0) {
      console.log('[DEBUG UI] Selected node IDs:', selectedNodes.map(n => n.id));
    }
  }, []);

  const onPaneClick = useCallback(() => {
    console.log('[DEBUG UI] Pane clicked - clearing selection');
    setNodeContextMenu(null);
  }, []);

  const onDragStart = useCallback((_event: React.MouseEvent, node: Node) => {
    console.log('[DEBUG UI] Drag start:', node.id);
    dragStateRef.current = { isDragging: true, nodeId: node.id, startTime: Date.now() };
  }, []);

  const onDragStop = useCallback((_event: React.MouseEvent, node: Node) => {
    const duration = Date.now() - dragStateRef.current.startTime;
    console.log('[DEBUG UI] Drag stop:', node.id, 'duration:', duration, 'ms');
    dragStateRef.current = { isDragging: false, nodeId: null, startTime: 0 };
  }, []);

  return (
    <ErrorBoundary>
      <div
        style={{ width: '100%', height: '100vh', background: '#0a0b0c' }}
        onContextMenu={(_e) => {
        }}
      >
        <BridgeStatusOverlay />

        {contextMenu && (
          <NodeMenu
            x={contextMenu.x}
            y={contextMenu.y}
            onSelect={handleNodeSelect}
            onClose={() => setContextMenu(null)}
          />
        )}

        {nodeContextMenu && (
          <NodeContextMenu
            x={nodeContextMenu.x}
            y={nodeContextMenu.y}
            node={nodeContextMenu.node.data as unknown as GraphNodeData}
            exposedParams={(nodeContextMenu.node.data as any).exposedParams || []}
            exposedParamInfo={exposedControlsList
              .filter(c => c.nodeId === nodeContextMenu.node.id)
              .map(c => ({ paramId: c.paramId, controlId: c.id, label: c.label }))}
            onAction={handleNodeContextAction}
            onClose={() => setNodeContextMenu(null)}
          />
        )}

        <ReactFlow
          nodes={nodes as any}
          edges={edges as any}
          onNodesChange={onNodesChange}
          onEdgesChange={onEdgesChange}
          onConnect={onConnect}
          onNodesDelete={onNodesDelete as any}
          onEdgesDelete={onEdgesDelete as any}
          onPaneContextMenu={onPaneContextMenu as any}
          onNodeContextMenu={onNodeContextMenu as any}
          onNodeDoubleClick={onNodeDoubleClick}
          onNodeClick={onNodeClick}
          onSelectionChange={onSelectionChange}
          onPaneClick={onPaneClick}
          onNodeDragStart={onDragStart}
          onNodeDragStop={onDragStop}
          nodeTypes={nodeTypes}
          fitView
          minZoom={0.1}
          maxZoom={2}
          nodesDraggable={true}
          nodesConnectable={true}
          elementsSelectable={true}
          nodesFocusable={false}
          selectNodesOnDrag={false}
          nodeDragThreshold={0}
          panOnDrag={[1, 2]}
          zoomActivationKeyCode={null}
          panOnScroll={true}
          selectionOnDrag={false}
          zoomOnDoubleClick={false}
          zoomOnScroll={true}
          snapToGrid={false}
          snapGrid={[10, 10]}
          defaultEdgeOptions={{
            animated: false,
            style: { strokeWidth: 2 }
          }}
          elevateNodesOnSelect={false}
          elevateEdgesOnSelect={false}
        >
          <Controls />
          <MiniMap 
            nodeColor="#1a1b1c"
            maskColor="rgba(10, 11, 12, 0.8)"
          />
          <Background 
            variant={BackgroundVariant.Dots} 
            gap={16} 
            size={1} 
            color="#252627"
          />
        </ReactFlow>
      </div>
    </ErrorBoundary>
  );
}

export default App;
