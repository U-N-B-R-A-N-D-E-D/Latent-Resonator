import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { bridge } from '../bridge';

export function LadderFilterNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const cutoff = (nodeData.parameters?.cutoff as number) || 5000;
  const resonance = (nodeData.parameters?.resonance as number) || 0.0;
  const mode = (nodeData.parameters?.mode as string) || 'lowpass';

  const handleCutoffChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    bridge.setParameter(nodeId, 'cutoff', parseFloat(e.target.value));
  };

  const handleResonanceChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    bridge.setParameter(nodeId, 'resonance', parseFloat(e.target.value));
  };

  const handleModeChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    bridge.setParameter(nodeId, 'mode', e.target.value);
  };

  return (
    <div className="node node-effect">
      <div className="node-header">
        <div className="node-title">{nodeData.displayName || 'LADDER FILTER'}</div>
      </div>

      <div className="node-body nodrag">
        {/* Cutoff slider */}
        <div className="node-param-row">
          <label className="node-param-label">Cutoff</label>
          <input
            type="range"
            min="20"
            max="20000"
            step="10"
            value={cutoff}
            onChange={handleCutoffChange}
            className="node-param-slider"
          />
          <span className="node-param-value">{cutoff.toFixed(0)} Hz</span>
        </div>

        {/* Resonance slider */}
        <div className="node-param-row">
          <label className="node-param-label">Resonance</label>
          <input
            type="range"
            min="0"
            max="1"
            step="0.01"
            value={resonance}
            onChange={handleResonanceChange}
            className="node-param-slider"
          />
          <span className="node-param-value">{resonance.toFixed(2)}</span>
        </div>

        {/* Filter mode selector */}
        <div className="node-param-row">
          <label className="node-param-label">Mode</label>
          <select
            value={mode}
            onChange={handleModeChange}
            className="node-param-select"
          >
            <option value="lowpass">Lowpass</option>
            <option value="highpass">Highpass</option>
            <option value="bandpass">Bandpass</option>
            <option value="notch">Notch</option>
          </select>
        </div>

        <div className="node-ports">
          {nodeData.ports?.filter(p => p.direction === 'input').map(port => (
            <Handle
              key={port.id}
              type="target"
              position={Position.Left}
              id={port.id}
              className={`handle-${port.signalType}`}
            />
          ))}
          {nodeData.ports?.filter(p => p.direction === 'output').map(port => (
            <Handle
              key={port.id}
              type="source"
              position={Position.Right}
              id={port.id}
              className={`handle-${port.signalType}`}
            />
          ))}
        </div>
      </div>
    </div>
  );
}
