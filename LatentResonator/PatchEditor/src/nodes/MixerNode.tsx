import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData, NodePort } from '../types';
import { KnobControl, ToggleControl } from '../components/NodeControls';

export function MixerNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const outputGain = (nodeData.parameters?.outputGain as number) ?? 1.0;
  const mute = (nodeData.parameters?.mute as boolean) ?? false;

  return (
    <div className={`react-flow__node-default node-category-${nodeData.category}`}>
      <div className="node-header">{nodeData.displayName || 'MIXER'}</div>

      <div className="node-body nodrag">
        {/* Large gain knob - Envion style */}
        <KnobControl
          nodeId={nodeId}
          paramId="outputGain"
          label="GAIN"
          value={outputGain}
          min={0}
          max={2}
          step={0.01}
          size="md"
          displayFormat={(v) => `${(v * 100).toFixed(0)}%`}
        />

        <div style={{ marginTop: '8px', display: 'flex', justifyContent: 'center' }} className="nodrag">
          <ToggleControl
            nodeId={nodeId}
            paramId="mute"
            label={mute ? 'MUTE' : 'ACTIVE'}
            value={mute}
          />
        </div>
      </div>

      {nodeData.ports?.map((port: NodePort) => (
        <Handle
          key={port.id}
          type={port.direction === 'input' ? 'target' : 'source'}
          position={port.direction === 'input' ? Position.Left : Position.Right}
          id={port.id}
          className={port.signalType === 'audio' ? 'handle-audio' : 'handle-control'}
          style={{
            top: port.direction === 'input' ? `${20 + parseInt(port.id.replace('in', '')) * 15}px` : undefined,
          }}
        />
      ))}

      <div className="node-telemetry">
        <div className="node-level-meter">
          <div className="node-level-fill" style={{ width: `${(outputGain / 2) * 100}%`, opacity: mute ? 0.2 : 1 }} />
        </div>
        <div className={`node-status-dot ${!mute ? 'active' : ''}`} />
      </div>
    </div>
  );
}
