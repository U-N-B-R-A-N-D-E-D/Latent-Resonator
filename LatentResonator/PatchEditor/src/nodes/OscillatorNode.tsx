import React, { useState, useCallback, useRef, useEffect } from 'react';
import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData, NodePort } from '../types';
import { bridge } from '../bridge';
import { KnobControl } from '../components/NodeControls';

export function OscillatorNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  
  // Local state for immediate UI responsiveness
  const [localFrequency, setLocalFrequency] = useState<number>(
    (nodeData.parameters?.frequency as number) || 110.0
  );
  const [localWaveform, setLocalWaveform] = useState<string>(
    (nodeData.parameters?.waveform as string) || 'sineOsc'
  );
  
  // Refs for throttling
  const lastUpdateTimeRef = useRef<number>(0);
  const rafIdRef = useRef<number | null>(null);
  const pendingValueRef = useRef<number | null>(null);
  
  // Sync local state with props (when graph updates from Swift side)
  useEffect(() => {
    const propFreq = (nodeData.parameters?.frequency as number) || 110.0;
    // Only update if significantly different to avoid fighting with local state
    if (Math.abs(propFreq - localFrequency) > 1.0) {
      setLocalFrequency(propFreq);
    }
  }, [nodeData.parameters?.frequency, localFrequency]);
  
  // Cleanup RAF on unmount
  useEffect(() => {
    return () => {
      if (rafIdRef.current !== null) {
        cancelAnimationFrame(rafIdRef.current);
      }
    };
  }, []);

  // Get telemetry data
  const telemetry = (nodeData as any).telemetry;
  const level = telemetry?.level || 0;
  const isActive = telemetry?.isActive || false;
  const levelPercent = Math.min(100, level * 100);

  // Handle frequency change with throttling
  const handleFreqChange = useCallback((newFreq: number) => {
    const now = Date.now();
    const timeSinceLastUpdate = now - lastUpdateTimeRef.current;

    // Update local state immediately for UI responsiveness
    setLocalFrequency(newFreq);
    pendingValueRef.current = newFreq;
    
    // Throttle bridge calls to 60fps max (16ms)
    if (timeSinceLastUpdate < 16) {
      if (rafIdRef.current === null) {
        rafIdRef.current = requestAnimationFrame(() => {
          if (pendingValueRef.current !== null) {
            bridge.setParameter(nodeId, 'frequency', pendingValueRef.current);
            lastUpdateTimeRef.current = Date.now();
            pendingValueRef.current = null;
          }
          rafIdRef.current = null;
        });
      }
    } else {
      // Direct update if enough time passed
      bridge.setParameter(nodeId, 'frequency', newFreq);
      lastUpdateTimeRef.current = now;
    }
  }, [nodeId]);

  const handleWaveChange = useCallback((e: React.ChangeEvent<HTMLSelectElement>) => {
    const newWaveform = e.target.value;
    setLocalWaveform(newWaveform);
    bridge.setParameter(nodeId, 'waveform', newWaveform);
  }, [nodeId]);

  // Format frequency display
  const formatFreq = (f: number) => {
    if (f >= 1000) return `${(f / 1000).toFixed(2)}k`;
    return `${f.toFixed(0)}`;
  };

  return (
    <div className={`react-flow__node-default node-category-${nodeData.category}`}>
      <div className="node-header">{nodeData.displayName || 'OSCILLATOR'}</div>

      <div className="node-body nodrag">
        {/* Knob control for frequency - Envion style */}
        <KnobControl
          nodeId={nodeId}
          paramId="frequency"
          label="FREQ"
          value={localFrequency}
          min={20}
          max={20000}
          step={1}
          size="md"
          displayFormat={formatFreq}
          onChange={handleFreqChange}
        />

        {/* Waveform selector */}
        <div className="node-param nodrag" onPointerDown={(e) => e.stopPropagation()}>
          <label className="node-param-label">Waveform</label>
          <select
            value={localWaveform}
            onChange={handleWaveChange}
            className="node-param-select nodrag"
            draggable={false}
          >
            <option value="sineOsc">Sine</option>
            <option value="sawOsc">Saw</option>
            <option value="squareOsc">Square</option>
            <option value="triangleOsc">Triangle</option>
            <option value="koenigSeed">Koenig Seed</option>
            <option value="noise">Noise</option>
          </select>
        </div>
      </div>

      {nodeData.ports?.map((port: NodePort) => (
        <Handle
          key={port.id}
          type={port.direction === 'input' ? 'target' : 'source'}
          position={port.direction === 'input' ? Position.Left : Position.Right}
          id={port.id}
          className={port.signalType === 'audio' ? 'handle-audio' : 'handle-control'}
        />
      ))}

      <div className="node-telemetry">
        <div className="node-level-meter">
          <div
            className="node-level-fill"
            style={{
              width: `${levelPercent}%`,
              backgroundColor: levelPercent > 80 ? '#ff3333' : levelPercent > 50 ? '#ffaa00' : '#00ff88'
            }}
          />
        </div>
        <div className={`node-status-dot ${isActive ? 'active' : ''}`} />
      </div>
    </div>
  );
}
