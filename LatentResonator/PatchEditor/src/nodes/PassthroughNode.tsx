import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData, NodePort } from '../types';
import { SliderControl } from '../components/NodeControls';

export function PassthroughNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const gain = (nodeData.parameters?.gain as number) ?? 1.0;

  return (
    <div className={`react-flow__node-default node-category-${nodeData.category}`}>
      <div className="node-header">{nodeData.displayName || 'PASS'}</div>

      <div className="node-body nodrag">
        <SliderControl
          nodeId={nodeId}
          paramId="gain"
          label="Gain"
          value={gain}
          min={0}
          max={2}
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
          <div className="node-level-fill" style={{ width: `${(gain / 2) * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
