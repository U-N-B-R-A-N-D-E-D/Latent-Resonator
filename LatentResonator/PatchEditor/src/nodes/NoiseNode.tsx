import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData, NodePort } from '../types';
import { SliderControl, SegmentControl } from '../components/NodeControls';

export function NoiseNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const amplitude = (nodeData.parameters?.amplitude as number) ?? 0.3;
  const noiseType = (nodeData.parameters?.noiseType as string) ?? 'white';

  const noiseOptions = [
    { value: 'white', label: 'White' },
    { value: 'pink', label: 'Pink' },
    { value: 'brown', label: 'Brown' },
  ];

  return (
    <div className={`react-flow__node-default node-category-${nodeData.category}`}>
      <div className="node-header">{nodeData.displayName || 'NOISE'}</div>

      <div className="node-body nodrag">
        <SegmentControl
          nodeId={nodeId}
          paramId="noiseType"
          value={noiseType}
          options={noiseOptions}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="amplitude"
          label="Amp"
          value={amplitude}
          min={0}
          max={1}
          step={0.01}
          displayFormat={(v) => v.toFixed(2)}
        />
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
          <div className="node-level-fill" style={{ width: `${amplitude * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
