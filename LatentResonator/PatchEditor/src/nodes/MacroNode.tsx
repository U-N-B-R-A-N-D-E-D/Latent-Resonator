import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData, NodePort } from '../types';

export function MacroNode({ data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  
  // Get telemetry data
  const telemetry = (nodeData as any).telemetry;
  const level = telemetry?.level || 0;
  const isActive = telemetry?.isActive || false;
  const levelPercent = Math.min(100, level * 100);
  
  const isExpanded = (nodeData.parameters as any)?.isExpanded || false;

  return (
    <div className="react-flow__node-default node-category-macro" style={{ 
      minWidth: '180px',
      background: 'linear-gradient(135deg, #2a1b3d 0%, #1a1b1c 100%)',
      border: isExpanded ? '2px solid #10b981' : '2px solid #8b5cf6',
      boxShadow: isExpanded 
        ? '0 0 30px rgba(16, 185, 129, 0.5)'
        : '0 0 20px rgba(139, 92, 246, 0.3)',
      position: 'relative'
    }}>
      <div className="node-header" style={{
        background: isExpanded ? '#10b981' : '#8b5cf6',
        color: '#0a0b0c',
        fontWeight: 'bold',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '6px 8px'
      }}>
        <span>{nodeData.displayName}</span>
        <span style={{ 
          fontSize: '10px',
          opacity: 0.7
        }}>
          {isExpanded ? '◢' : '▶'}
        </span>
      </div>
      
      <div className="node-body nodrag" style={{ padding: '12px 8px' }}>
        <div style={{
          fontSize: '10px',
          color: isExpanded ? '#10b981' : '#a78bfa',
          textAlign: 'center',
          marginBottom: '4px'
        }}>
          {isExpanded ? 'EXPANDED' : 'MACRO'}
        </div>
        <div style={{
          fontSize: '9px',
          color: '#666',
          textAlign: 'center'
        }}>
          {Object.keys(nodeData.parameters || {}).length} params
        </div>
        <div style={{
          fontSize: '8px',
          color: '#888',
          textAlign: 'center',
          marginTop: '4px',
          fontStyle: 'italic'
        }}>
          double-click to {isExpanded ? 'collapse' : 'expand'}
        </div>
      </div>
      
      {nodeData.ports.map((port: NodePort) => (
        <Handle
          key={port.id}
          type={port.direction === 'input' ? 'target' : 'source'}
          position={port.direction === 'input' ? Position.Left : Position.Right}
          id={port.id}
          style={{
            background: port.signalType === 'audio' ? 'var(--signal-audio)' : 'var(--signal-control)',
            border: isExpanded ? '2px solid #10b981' : '2px solid #8b5cf6',
            width: '12px',
            height: '12px'
          }}
        />
      ))}
      
      <div className="node-telemetry">
        <div className="node-level-meter">
          <div 
            className="node-level-fill" 
            style={{ 
              width: `${levelPercent}%`,
              backgroundColor: levelPercent > 80 ? '#ff3333' : levelPercent > 50 ? '#ffaa00' : '#a78bfa'
            }} 
          />
        </div>
        <div className={`node-status-dot ${isActive ? 'active' : ''}`} />
      </div>
    </div>
  );
}
