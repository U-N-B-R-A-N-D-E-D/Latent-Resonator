import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { KnobControl } from '../components/NodeControls';
import { bridge } from '../bridge';

export function ManualControlNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const value = (nodeData.parameters?.value as number) ?? 0.5;
  const minValue = (nodeData.parameters?.minValue as number) ?? 0.0;
  const maxValue = (nodeData.parameters?.maxValue as number) ?? 1.0;

  const handleMinChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const v = parseFloat(e.target.value);
    if (!isNaN(v)) {
      bridge.setParameter(nodeId, 'minValue', v);
    }
  };

  const handleMaxChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const v = parseFloat(e.target.value);
    if (!isNaN(v)) {
      bridge.setParameter(nodeId, 'maxValue', v);
    }
  };

  return (
    <div className="react-flow__node-default node-category-control">
      <div className="node-header">{nodeData.displayName || 'MANUAL CV'}</div>

      <div className="node-body nodrag">
        {/* Large knob for the main value - Envion style */}
        <KnobControl
          nodeId={nodeId}
          paramId="value"
          label="OUTPUT"
          value={value}
          min={minValue}
          max={maxValue}
          step={0.001}
          size="lg"
          displayFormat={(v) => v.toFixed(2)}
        />

        {/* Min/Max configuration row */}
        <div style={{ display: 'flex', gap: '6px', marginTop: '8px' }} className="nodrag">
          <div style={{ flex: 1 }}>
            <label style={{ fontSize: '7px', textTransform: 'uppercase', color: 'var(--text-secondary)' }}>Min</label>
            <input
              type="number"
              value={minValue.toFixed(2)}
              onChange={handleMinChange}
              className="node-value-input nodrag"
              style={{ width: '100%' }}
              draggable={false}
            />
          </div>
          <div style={{ flex: 1 }}>
            <label style={{ fontSize: '7px', textTransform: 'uppercase', color: 'var(--text-secondary)' }}>Max</label>
            <input
              type="number"
              value={maxValue.toFixed(2)}
              onChange={handleMaxChange}
              className="node-value-input nodrag"
              style={{ width: '100%' }}
              draggable={false}
            />
          </div>
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
          <div className="node-level-fill" style={{ width: `${((value - minValue) / (maxValue - minValue)) * 100}%`, background: 'var(--neon-ambar)' }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
