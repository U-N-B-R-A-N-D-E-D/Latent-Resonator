import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl } from '../components/NodeControls';

export function SpectralAnalyzerNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const centroid = nodeData.telemetry?.spectralCentroid || 0;
  const flatness = nodeData.telemetry?.spectralFlatness || 0;
  const smoothing = (nodeData.parameters?.smoothing as number) ?? 0.5;

  return (
    <div className="react-flow__node-default node-category-analysis">
      <div className="node-header">{nodeData.displayName || 'ANALYZER'}</div>

      <div className="node-body nodrag">
        {/* Real-time spectral displays */}
        <div style={{ marginBottom: '8px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '8px', marginBottom: '2px' }}>
            <span style={{ color: 'var(--text-secondary)' }}>CENTROID</span>
            <span style={{ color: 'var(--neon-turquesa)' }}>{centroid.toFixed(3)}</span>
          </div>
          <div className="node-level-meter" style={{ height: '6px' }}>
            <div className="node-level-fill" style={{ width: `${centroid * 100}%` }} />
          </div>
        </div>

        <div style={{ marginBottom: '8px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '8px', marginBottom: '2px' }}>
            <span style={{ color: 'var(--text-secondary)' }}>FLATNESS</span>
            <span style={{ color: 'var(--neon-ambar)' }}>{flatness.toFixed(3)}</span>
          </div>
          <div className="node-level-meter" style={{ height: '6px' }}>
            <div className="node-level-fill" style={{ width: `${flatness * 100}%`, background: 'var(--neon-ambar)' }} />
          </div>
        </div>

        <SliderControl
          nodeId={nodeId}
          paramId="smoothing"
          label="Smooth"
          value={smoothing}
          min={0}
          max={1}
          step={0.01}
          displayFormat={(v) => `${(v * 100).toFixed(0)}%`}
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
          <div className="node-level-fill" style={{ width: `${centroid * 100}%` }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
