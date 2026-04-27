import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, SegmentControl } from '../components/NodeControls';

export function ACEStepInferenceNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const guidanceScale = (nodeData.parameters?.guidanceScale as number) ?? 10.0;
  const numSteps = (nodeData.parameters?.numSteps as number) ?? 10;
  const taskType = (nodeData.parameters?.taskType as string) ?? 'cover';
  const isProcessing = nodeData.telemetry?.inferenceStatus === 'processing' || false;

  const taskOptions = [
    { value: 'cover', label: 'Cover' },
    { value: 'variation', label: 'Vary' },
    { value: 'inpaint', label: 'Inpaint' },
    { value: 'superres', label: 'Super' },
  ];

  return (
    <div className="react-flow__node-default node-category-neural">
      <div className="node-header">
        {nodeData.displayName || 'ACE STEP'}
        <span style={{ marginLeft: 'auto', fontSize: '10px' }}>
          {isProcessing ? '⚡' : '○'}
        </span>
      </div>

      <div className="node-body nodrag">
        <SegmentControl
          nodeId={nodeId}
          paramId="taskType"
          value={taskType}
          options={taskOptions}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="guidanceScale"
          label="CFG Scale"
          value={guidanceScale}
          min={1}
          max={50}
          step={0.5}
          displayFormat={(v) => v.toFixed(1)}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="numSteps"
          label="Steps"
          value={numSteps}
          min={1}
          max={100}
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
          <div
            className="node-level-fill"
            style={{
              width: `${(numSteps / 100) * 100}%`,
              animation: isProcessing ? 'pulse 0.5s ease-in-out infinite' : 'none',
            }}
          />
        </div>
        <div className={`node-status-dot ${isProcessing ? 'processing' : 'active'}`} />
      </div>
    </div>
  );
}
