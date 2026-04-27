// Type definitions for the node graph and bridge protocol

export type SignalType = 'audio' | 'control' | 'gate' | 'text';
export type PortDirection = 'input' | 'output';
export type NodeCategory = 'source' | 'spectral' | 'filter' | 'effect' | 'neural' | 'control' | 'routing' | 'analysis';

export interface NodePort {
  id: string;
  label: string;
  signalType: SignalType;
  direction: PortDirection;
}

export interface GraphNodeData {
  id: string;
  type: string;
  displayName: string;
  category: NodeCategory;
  ports: NodePort[];
  parameters: Record<string, any>;
  x?: number;
  y?: number;
  telemetry?: NodeTelemetry;
  exposedParams?: string[]; // Phase 3: List of parameter IDs that are exposed
}

export interface GraphEdgeData {
  id: string;
  sourceNodeId: string;
  sourcePortId: string;
  targetNodeId: string;
  targetPortId: string;
  signalType: SignalType;
}

export interface NodeTelemetry {
  nodeId: string;
  level: number;
  isActive: boolean;
  rmsLevel?: number;
  spectralCentroid?: number;
  spectralFlatness?: number;
  inferenceStatus?: 'idle' | 'processing' | 'complete' | 'error';
  iterationCount?: number;
  cycleTimeMs?: number;
}

export interface BridgeStatus {
  status: 'DISCONNECTED' | 'CONNECTING' | 'CONNECTED' | 'MODEL_LOADED' | 'ERROR' | 'RECOVERING';
  isModelLoaded: boolean;
  remoteDevice: string;
  remoteModelType: string;
  lastError?: string;
  consecutiveFailures: number;
  remoteInferenceCount: number;
}

export interface BridgeMessage {
  action: string;
  [key: string]: any;
}

export interface BridgeEvent {
  event: string;
  data: any;
  timestamp: number;
}
