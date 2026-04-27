import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, SegmentControl } from '../components/NodeControls';

export function WaveshaperNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const drive = (nodeData.parameters?.drive as number) ?? 1.0;
  const mix = (nodeData.parameters?.mix as number) ?? 0.5;
  const shape = (nodeData.parameters?.shape as string) ?? 'tanh';

  const shapeOptions = [
    { value: 'tanh', label: 'Tanh' },
    { value: 'softclip', label: 'Soft' },
    { value: 'hardclip', label: 'Hard' },
    { value: 'sinfold', label: 'Fold' },
    { value: 'sine', label: 'Sine' },
  ];

  return (
    <div className="react-flow__node-default node-category-effect">
      <div className="node-header">{nodeData.displayName || 'WAVESHAPER'}</div>

      <div className="node-body nodrag">
        <SegmentControl
          nodeId={nodeId}
          paramId="shape"
          value={shape}
          options={shapeOptions}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="drive"
          label="Drive"
          value={drive}
          min={0.1}
          max={10}
          step={0.1}
          displayFormat={(v) => `${v.toFixed(1)}x`}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="mix"
          label="Mix"
          value={mix}
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
          <div className="node-level-fill" style={{ width: `${(drive / 10) * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
