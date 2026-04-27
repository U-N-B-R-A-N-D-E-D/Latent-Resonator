import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { KnobControl, ToggleControl } from '../components/NodeControls';

export function DelayLineNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const delayTime = (nodeData.parameters?.delayTime as number) ?? 0.25;
  const feedback = (nodeData.parameters?.feedback as number) ?? 0.5;
  const wetDryMix = (nodeData.parameters?.wetDryMix as number) ?? 0.3;
  const syncToTempo = (nodeData.parameters?.syncToTempo as boolean) ?? false;

  return (
    <div className="react-flow__node-default node-category-effect">
      <div className="node-header">{nodeData.displayName || 'DELAY'}</div>

      <div className="node-body nodrag">
        {/* Row of knobs - Envion style */}
        <div className="node-knobs-row">
          <KnobControl
            nodeId={nodeId}
            paramId="delayTime"
            label="TIME"
            value={delayTime}
            min={0.001}
            max={2.0}
            step={0.001}
            size="sm"
            displayFormat={(v) => `${(v * 1000).toFixed(0)}ms`}
          />

          <KnobControl
            nodeId={nodeId}
            paramId="feedback"
            label="FBK"
            value={feedback}
            min={0}
            max={1.5}
            step={0.01}
            size="sm"
            displayFormat={(v) => v.toFixed(2)}
          />

          <KnobControl
            nodeId={nodeId}
            paramId="wetDryMix"
            label="MIX"
            value={wetDryMix}
            min={0}
            max={1}
            step={0.01}
            size="sm"
            displayFormat={(v) => `${(v * 100).toFixed(0)}%`}
          />
        </div>

        <div style={{ marginTop: '8px', display: 'flex', gap: '4px', justifyContent: 'center' }} className="nodrag">
          <ToggleControl
            nodeId={nodeId}
            paramId="syncToTempo"
            label="SYNC"
            value={syncToTempo}
          />
        </div>
      </div>

      {nodeData.ports?.map((port) => (
        <Handle
          key={port.id}
          type={port.direction === 'input' ? 'target' : 'source'}
          position={port.direction === 'input' ? Position.Left : Position.Right}
          id={port.id}
          className={port.signalType === 'audio' ? 'handle-audio' : 'handle-control'}
        />
      ))}

      <div className="node-telemetry">
        <div className="node-level-meter">
          <div className="node-level-fill" style={{ width: `${Math.min(100, feedback * 67)}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
