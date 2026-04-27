import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl } from '../components/NodeControls';

export function TunableResonatorNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const frequency = (nodeData.parameters?.frequency as number) ?? 440;
  const decay = (nodeData.parameters?.decay as number) ?? 2.0;
  const harmonicCount = (nodeData.parameters?.harmonicCount as number) ?? 4;

  return (
    <div className="react-flow__node-default node-category-filter">
      <div className="node-header">{nodeData.displayName || 'RESONATOR'}</div>

      <div className="node-body nodrag">
        <SliderControl
          nodeId={nodeId}
          paramId="frequency"
          label="Freq"
          value={frequency}
          min={20}
          max={8000}
          step={1}
          displayFormat={(v) => v < 1000 ? `${v.toFixed(0)}Hz` : `${(v / 1000).toFixed(1)}k`}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="decay"
          label="Decay"
          value={decay}
          min={0.1}
          max={10}
          step={0.1}
          displayFormat={(v) => `${v.toFixed(1)}s`}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="harmonicCount"
          label="Partials"
          value={harmonicCount}
          min={1}
          max={16}
          step={1}
          displayFormat={(v) => v.toFixed(0)}
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
          <div className="node-level-fill" style={{ width: `${(decay / 10) * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
