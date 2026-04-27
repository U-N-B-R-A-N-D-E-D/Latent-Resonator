import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, ToggleControl } from '../components/NodeControls';
import { useState, useCallback } from 'react';

export function StepSequencerNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const bpm = (nodeData.parameters?.bpm as number) ?? 120;
  const steps = (nodeData.parameters?.steps as number) ?? 16;
  const gateLength = (nodeData.parameters?.gateLength as number) ?? 0.5;
  const isRunning = (nodeData.parameters?.isRunning as boolean) ?? false;

  // Local state for step pattern (would sync with Swift)
  const [pattern, setPattern] = useState<boolean[]>(Array(16).fill(false).map((_, i) => [0, 4, 8, 12].includes(i)));

  const toggleStep = useCallback((index: number) => {
    setPattern(prev => {
      const next = [...prev];
      next[index] = !next[index];
      return next;
    });
    // TODO: Sync with Swift via bridge
  }, []);

  return (
    <div className="react-flow__node-default node-category-control">
      <div className="node-header">{nodeData.displayName || 'STEP SEQ'}</div>

      <div className="node-body nodrag">
        <div style={{ display: 'flex', gap: '4px', marginBottom: '8px' }}>
          <ToggleControl
            nodeId={nodeId}
            paramId="isRunning"
            label={isRunning ? 'STOP' : 'PLAY'}
            value={isRunning}
          />
        </div>

        <SliderControl
          nodeId={nodeId}
          paramId="bpm"
          label="BPM"
          value={bpm}
          min={20}
          max={300}
          step={1}
          displayFormat={(v) => v.toFixed(0)}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="gateLength"
          label="Gate"
          value={gateLength}
          min={0.01}
          max={1}
          step={0.01}
          displayFormat={(v) => `${(v * 100).toFixed(0)}%`}
        />

        {/* Step grid */}
        <div className="node-step-grid" style={{ marginTop: '8px' }}>
          {pattern.slice(0, steps).map((active, idx) => (
            <button
              key={idx}
              className={`node-step-btn ${active ? 'active' : ''}`}
              onClick={() => toggleStep(idx)}
              title={`Step ${idx + 1}`}
            />
          ))}
        </div>
      </div>

      {nodeData.ports?.map((port) => (
        <Handle
          key={port.id}
          type={port.direction === 'input' ? 'target' : 'source'}
          position={port.direction === 'input' ? Position.Left : Position.Right}
          id={port.id}
          style={{
            background: port.signalType === 'audio' ? 'var(--signal-audio)' : 'var(--signal-control)',
          }}
        />
      ))}

      <div className="node-telemetry">
        <div className="node-level-meter">
          <div className="node-level-fill" style={{ width: `${(bpm / 300) * 100}%`, background: 'var(--neon-ambar)' }} />
        </div>
        <div className={`node-status-dot ${isRunning ? 'active' : ''}`} />
      </div>
    </div>
  );
}
