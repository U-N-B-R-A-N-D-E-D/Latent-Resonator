import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl } from '../components/NodeControls';

export function CombFilterNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const feedback = (nodeData.parameters?.feedback as number) ?? 0.5;
  const baseDelay = (nodeData.parameters?.baseDelay as number) ?? 127;
  const tapCount = (nodeData.parameters?.tapCount as number) ?? 4;

  return (
    <div className="react-flow__node-default node-category-filter">
      <div className="node-header">{nodeData.displayName || 'COMB FILTER'}</div>

      <div className="node-body nodrag">
        <SliderControl
          nodeId={nodeId}
          paramId="feedback"
          label="Feedback"
          value={feedback}
          min={-0.99}
          max={0.99}
          step={0.01}
          displayFormat={(v) => v.toFixed(2)}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="baseDelay"
          label="Delay"
          value={baseDelay}
          min={1}
          max={1024}
          step={1}
          displayFormat={(v) => v.toFixed(0)}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="tapCount"
          label="Taps"
          value={tapCount}
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
          <div className="node-level-fill" style={{ width: `${(feedback + 0.99) / 1.98 * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
