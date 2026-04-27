import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { SliderControl, SegmentControl } from '../components/NodeControls';

export function IFFTSynthesisNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const fftSize = (nodeData.parameters?.fftSize as number) ?? 2048;
  const hopSize = (nodeData.parameters?.hopSize as number) ?? 512;
  const windowType = (nodeData.parameters?.windowType as string) ?? 'hann';

  const windowOptions = [
    { value: 'hann', label: 'Hann' },
    { value: 'hamming', label: 'Hamm' },
    { value: 'blackman', label: 'Black' },
    { value: 'rect', label: 'Rect' },
  ];

  return (
    <div className="react-flow__node-default node-category-spectral">
      <div className="node-header">{nodeData.displayName || 'IFFT'}</div>

      <div className="node-body nodrag">
        <SegmentControl
          nodeId={nodeId}
          paramId="windowType"
          value={windowType}
          options={windowOptions}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="fftSize"
          label="FFT Size"
          value={fftSize}
          min={256}
          max={8192}
          step={256}
          displayFormat={(v) => v.toFixed(0)}
        />

        <SliderControl
          nodeId={nodeId}
          paramId="hopSize"
          label="Hop"
          value={hopSize}
          min={64}
          max={4096}
          step={64}
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
          <div className="node-level-fill" style={{ width: '100%' }} />
        </div>
        <div className="node-status-dot active" />
      </div>
    </div>
  );
}
