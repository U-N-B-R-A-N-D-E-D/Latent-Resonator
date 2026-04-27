import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, SegmentControl } from '../components/NodeControls';

export function AgitationNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const rate = (nodeData.parameters?.rate as number) ?? 0.5;
  const depth = (nodeData.parameters?.depth as number) ?? 0.5;
  const waveform = (nodeData.parameters?.waveform as string) ?? 'sine';

  const waveformOptions = [
    { value: 'sine', label: 'Sine' },
    { value: 'saw', label: 'Saw' },
    { value: 'square', label: 'Square' },
    { value: 'triangle', label: 'Tri' },
    { value: 'random', label: 'Rand' },
  ];

  return (
    <div className="react-flow__node-default node-category-control">
      <div className="node-header">{nodeData.displayName || 'AGITATION'}</div>

      <div className="node-body nodrag">
        <SegmentControl
          nodeId={nodeId}
          paramId="waveform"
          value={waveform}
          options={waveformOptions}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="rate"
          label="Rate"
          value={rate}
          min={0.01}
          max={20}
          step={0.01}
          displayFormat={(v) => v < 1 ? `${v.toFixed(2)}Hz` : `${v.toFixed(1)}Hz`}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="depth"
          label="Depth"
          value={depth}
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
          <div className="node-level-fill" style={{ width: `${depth * 100}%`, background: 'var(--neon-ambar)', animation: 'pulse 0.5s ease-in-out infinite' }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
