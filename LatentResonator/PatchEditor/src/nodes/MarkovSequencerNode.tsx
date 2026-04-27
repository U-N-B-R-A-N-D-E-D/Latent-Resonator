import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, ToggleControl } from '../components/NodeControls';

export function MarkovSequencerNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const currentState = (nodeData.parameters?.currentState as number) ?? 0;
  const numStates = (nodeData.parameters?.numStates as number) ?? 4;
  const transitionEntropy = (nodeData.parameters?.transitionEntropy as number) ?? 0.3;
  const isRunning = (nodeData.parameters?.isRunning as boolean) ?? false;

  return (
    <div className="react-flow__node-default node-category-control">
      <div className="node-header">{nodeData.displayName || 'MARKOV SEQ'}</div>

      <div className="node-body nodrag">
        <div style={{ display: 'flex', gap: '4px', marginBottom: '8px' }}>
          <ToggleControl
            nodeId={nodeId}
            paramId="isRunning"
            label={isRunning ? 'STOP' : 'PLAY'}
            value={isRunning}
          />
        </div>

        {/* State indicators */}
        <div style={{
          display: 'flex',
          gap: '3px',
          justifyContent: 'center',
          margin: '8px 0',
          padding: '6px',
          background: 'var(--panel-hollow)',
          borderRadius: '3px',
        }}>
          {Array.from({ length: Math.min(numStates, 8) }, (_, i) => (
            <div
              key={i}
              style={{
                width: '8px',
                height: '8px',
                borderRadius: '50%',
                background: i === currentState ? 'var(--neon-ambar)' : 'rgba(255,255,255,0.1)',
                boxShadow: i === currentState ? '0 0 4px var(--neon-ambar)' : 'none',
              }}
            />
          ))}
        </div>

        <SliderControl
          nodeId={nodeId}
          paramId="numStates"
          label="States"
          value={numStates}
          min={2}
          max={8}
          step={1}
          displayFormat={(v) => v.toFixed(0)}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="transitionEntropy"
          label="Chaos"
          value={transitionEntropy}
          min={0}
          max={1}
          step={0.01}
          displayFormat={(v) => `${(v * 100).toFixed(0)}%`}
        />
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
          <div className="node-level-fill" style={{ width: `${transitionEntropy * 100}%`, background: 'var(--neon-ambar)' }} />
        </div>
        <div className={`node-status-dot ${isRunning ? 'active' : ''}`} />
      </div>
    </div>
  );
}
