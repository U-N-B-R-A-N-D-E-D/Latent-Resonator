import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, SegmentControl } from '../components/NodeControls';

export function SpectralNoiseNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const entropyLevel = (nodeData.parameters?.entropyLevel as number) ?? 0.0;
  const distribution = (nodeData.parameters?.distribution as string) ?? 'uniform';

  const distributionOptions = [
    { value: 'uniform', label: 'Uniform' },
    { value: 'gaussian', label: 'Gauss' },
    { value: 'pink', label: 'Pink' },
    { value: 'impulse', label: 'Impulse' },
  ];

  return (
    <div className="react-flow__node-default node-category-spectral">
      <div className="node-header">{nodeData.displayName || 'SPEC NOISE'}</div>

      <div className="node-body nodrag">
        <SegmentControl
          nodeId={nodeId}
          paramId="distribution"
          value={distribution}
          options={distributionOptions}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="entropyLevel"
          label="Entropy"
          value={entropyLevel}
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
          <div className="node-level-fill" style={{ width: `${entropyLevel * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
