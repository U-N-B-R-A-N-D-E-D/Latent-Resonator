import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, SegmentControl } from '../components/NodeControls';

export function SpectralGranularityNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const granularity = (nodeData.parameters?.granularity as number) ?? 0.0;
  const mode = (nodeData.parameters?.mode as string) ?? 'smooth';

  const modeOptions = [
    { value: 'smooth', label: 'Smooth' },
    { value: 'stepped', label: 'Step' },
    { value: 'random', label: 'Rand' },
  ];

  return (
    <div className="react-flow__node-default node-category-spectral">
      <div className="node-header">{nodeData.displayName || 'GRANULARITY'}</div>

      <div className="node-body nodrag">
        <SegmentControl
          nodeId={nodeId}
          paramId="mode"
          value={mode}
          options={modeOptions}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="granularity"
          label="Amount"
          value={granularity}
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
          <div className="node-level-fill" style={{ width: `${granularity * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
