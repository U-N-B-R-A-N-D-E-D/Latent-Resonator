import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl } from '../components/NodeControls';

export function BitCrusherNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const depth = (nodeData.parameters?.depth as number) ?? 8;
  const sampleRateReduction = (nodeData.parameters?.sampleRateReduction as number) ?? 1;

  return (
    <div className="react-flow__node-default node-category-effect">
      <div className="node-header">{nodeData.displayName || 'BIT CRUSHER'}</div>

      <div className="node-body nodrag">
        <SliderControl
          nodeId={nodeId}
          paramId="depth"
          label="Depth"
          value={depth}
          min={1}
          max={32}
          step={1}
          displayFormat={(v) => v.toFixed(0)}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="sampleRateReduction"
          label="Rate Div"
          value={sampleRateReduction}
          min={1}
          max={16}
          step={1}
          displayFormat={(v) => `${v}x`}
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
          <div className="node-level-fill" style={{ width: `${(depth / 32) * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
