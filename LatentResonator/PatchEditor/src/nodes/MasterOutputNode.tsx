import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData, NodePort } from '../types';
import { SliderControl, ToggleControl } from '../components/NodeControls';

export function MasterOutputNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const masterGain = (nodeData.parameters?.masterGain as number) ?? 1.0;
  const mute = (nodeData.parameters?.mute as boolean) ?? false;

  return (
    <div className={`react-flow__node-default node-category-${nodeData.category}`}>
      <div className="node-header">{nodeData.displayName || 'MASTER'}</div>

      <div className="node-body nodrag">
        <SliderControl
          nodeId={nodeId}
          paramId="masterGain"
          label="Gain"
          value={masterGain}
          min={0}
          max={2}
          step={0.01}
          displayFormat={(v) => `${(v * 100).toFixed(0)}%`}
        />

        <div style={{ marginTop: '6px' }}>
          <ToggleControl
            nodeId={nodeId}
            paramId="mute"
            label={mute ? 'MUTED' : 'ACTIVE'}
            value={mute}
          />
        </div>
      </div>

      {nodeData.ports?.map((port: NodePort) => (
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
          <div
            className="node-level-fill"
            style={{
              width: `${(masterGain / 2) * 100}%`,
              background: mute ? '#666' : undefined,
              opacity: mute ? 0.3 : 1,
            }}
          />
        </div>
        <div className={`node-status-dot ${!mute ? 'active' : ''}`} />
      </div>
    </div>
  );
}
