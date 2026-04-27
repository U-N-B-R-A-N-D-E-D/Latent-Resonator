import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl } from '../components/NodeControls';

export function PeakNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const attack = (nodeData.parameters?.attack as number) ?? 0.01;
  const hold = (nodeData.parameters?.hold as number) ?? 0.1;
  const decay = (nodeData.parameters?.decay as number) ?? 0.3;
  const threshold = (nodeData.parameters?.threshold as number) ?? 0.5;

  return (
    <div className="react-flow__node-default node-category-control">
      <div className="node-header">{nodeData.displayName || 'PEAK'}</div>

      <div className="node-body nodrag">
        <SliderControl
          nodeId={nodeId}
          paramId="threshold"
          label="Threshold"
          value={threshold}
          min={0}
          max={1}
          step={0.01}
          displayFormat={(v) => v.toFixed(2)}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="attack"
          label="Attack"
          value={attack}
          min={0.001}
          max={0.5}
          step={0.001}
          displayFormat={(v) => `${(v * 1000).toFixed(0)}ms`}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="hold"
          label="Hold"
          value={hold}
          min={0.01}
          max={1}
          step={0.01}
          displayFormat={(v) => `${(v * 1000).toFixed(0)}ms`}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="decay"
          label="Decay"
          value={decay}
          min={0.01}
          max={2}
          step={0.01}
          displayFormat={(v) => `${v.toFixed(2)}s`}
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
          <div className="node-level-fill" style={{ width: `${threshold * 100}%`, background: 'var(--neon-ambar)' }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
