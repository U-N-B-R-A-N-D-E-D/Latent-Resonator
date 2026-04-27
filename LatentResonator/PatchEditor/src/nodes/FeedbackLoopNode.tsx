import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, ToggleControl } from '../components/NodeControls';

export function FeedbackLoopNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const delayTime = (nodeData.parameters?.delayTime as number) ?? 0.1;
  const feedback = (nodeData.parameters?.feedback as number) ?? 0.5;
  const freeze = (nodeData.parameters?.freeze as boolean) ?? false;

  return (
    <div className="react-flow__node-default node-category-neural">
      <div className="node-header">{nodeData.displayName || 'FEEDBACK'}</div>

      <div className="node-body nodrag">
        <SliderControl
          nodeId={nodeId}
          paramId="delayTime"
          label="Delay"
          value={delayTime}
          min={0.001}
          max={2}
          step={0.001}
          displayFormat={(v) => `${v.toFixed(3)}s`}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="feedback"
          label="Feedback"
          value={feedback}
          min={0}
          max={1.5}
          step={0.01}
          displayFormat={(v) => v.toFixed(2)}
        />

        <div style={{ marginTop: '6px' }}>
          <ToggleControl
            nodeId={nodeId}
            paramId="freeze"
            label={freeze ? 'UNFREEZE' : 'FREEZE'}
            value={freeze}
          />
        </div>
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
          <div className="node-level-fill" style={{ width: `${(feedback / 1.5) * 100}%` }} />
        </div>
        <div className={`node-status-dot ${freeze ? 'processing' : 'active'}`} />
      </div>
    </div>
  );
}
