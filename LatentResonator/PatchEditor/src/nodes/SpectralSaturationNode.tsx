import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, SegmentControl } from '../components/NodeControls';

export function SpectralSaturationNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const guidanceScale = (nodeData.parameters?.guidanceScale as number) ?? 10.0;
  const saturationMode = (nodeData.parameters?.saturationMode as string) ?? 'soft';

  const modeOptions = [
    { value: 'soft', label: 'Soft' },
    { value: 'hard', label: 'Hard' },
    { value: 'tube', label: 'Tube' },
    { value: 'tape', label: 'Tape' },
  ];

  return (
    <div className="react-flow__node-default node-category-spectral">
      <div className="node-header">{nodeData.displayName || 'SPECTRAL SAT'}</div>

      <div className="node-body nodrag">
        <SegmentControl
          nodeId={nodeId}
          paramId="saturationMode"
          value={saturationMode}
          options={modeOptions}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="guidanceScale"
          label="Drive"
          value={guidanceScale}
          min={1}
          max={50}
          step={0.1}
          displayFormat={(v) => v.toFixed(1)}
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
          <div className="node-level-fill" style={{ width: `${(guidanceScale / 50) * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
