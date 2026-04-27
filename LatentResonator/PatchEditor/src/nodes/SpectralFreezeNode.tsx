import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, ToggleControl } from '../components/NodeControls';

export function SpectralFreezeNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const freezeActive = (nodeData.parameters?.freezeActive as boolean) ?? false;
  const blendAmount = (nodeData.parameters?.blendAmount as number) ?? 0.5;
  const crossfade = (nodeData.parameters?.crossfade as number) ?? 0.5;

  return (
    <div className="react-flow__node-default node-category-spectral">
      <div className="node-header">
        {nodeData.displayName || 'FREEZE'}
        <span style={{ marginLeft: 'auto', fontSize: '10px', opacity: freezeActive ? 1 : 0.3 }}>
          {freezeActive ? '❄' : '○'}
        </span>
      </div>

      <div className="node-body nodrag">
        <div style={{ display: 'flex', gap: '4px', marginBottom: '8px' }}>
          <ToggleControl
            nodeId={nodeId}
            paramId="freezeActive"
            label={freezeActive ? 'UNFREEZE' : 'FREEZE'}
            value={freezeActive}
          />
        </div>

        <SliderControl
          nodeId={nodeId}
          paramId="blendAmount"
          label="Blend"
          value={blendAmount}
          min={0}
          max={1}
          step={0.01}
          displayFormat={(v) => `${(v * 100).toFixed(0)}%`}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="crossfade"
          label="X-Fade"
          value={crossfade}
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
          <div
            className="node-level-fill"
            style={{
              width: `${blendAmount * 100}%`,
              background: freezeActive ? 'var(--neon-turquesa)' : '#888',
              opacity: freezeActive ? 1 : 0.3,
            }}
          />
        </div>
        <div className={`node-status-dot ${freezeActive ? 'processing' : ''}`} />
      </div>
    </div>
  );
}
