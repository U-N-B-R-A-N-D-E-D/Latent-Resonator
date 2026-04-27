import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { useState, useCallback } from 'react';
import { bridge } from '../bridge';
import { SliderControl } from '../components/NodeControls';

export function SemanticEQNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  const prompt = (nodeData.parameters?.prompt as string) ?? '';
  const strength = (nodeData.parameters?.strength as number) ?? 0.5;

  const [isEditing, setIsEditing] = useState(false);
  const [editPrompt, setEditPrompt] = useState(prompt);

  const handleSave = useCallback(() => {
    bridge.setParameter(nodeId, 'prompt', editPrompt);
    setIsEditing(false);
  }, [nodeId, editPrompt]);

  return (
    <div className="react-flow__node-default node-category-spectral">
      <div className="node-header">{nodeData.displayName || 'SEMANTIC EQ'}</div>

      <div className="node-body nodrag">
        {isEditing ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '6px', marginBottom: '8px' }}>
            <input
              type="text"
              value={editPrompt}
              onChange={(e) => setEditPrompt(e.target.value)}
              style={{
                width: '100%',
                background: 'var(--panel-hollow)',
                border: '1px solid var(--border)',
                borderRadius: '3px',
                color: 'var(--text-primary)',
                fontFamily: 'inherit',
                fontSize: '9px',
                padding: '6px',
              }}
              placeholder="e.g., warm, bright, hollow..."
              autoFocus
              onKeyDown={(e) => {
                if (e.key === 'Enter') handleSave();
                if (e.key === 'Escape') {
                  setEditPrompt(prompt);
                  setIsEditing(false);
                }
              }}
            />
            <div style={{ display: 'flex', gap: '4px' }}>
              <button
                onClick={handleSave}
                style={{
                  flex: 1,
                  padding: '4px 8px',
                  background: 'var(--neon-turquesa)',
                  border: 'none',
                  borderRadius: '3px',
                  color: 'var(--titanio-bottom)',
                  fontSize: '9px',
                  fontWeight: 600,
                  cursor: 'pointer',
                }}
              >
                SAVE
              </button>
              <button
                onClick={() => {
                  setEditPrompt(prompt);
                  setIsEditing(false);
                }}
                style={{
                  flex: 1,
                  padding: '4px 8px',
                  background: 'var(--panel-hollow)',
                  border: '1px solid var(--border)',
                  borderRadius: '3px',
                  color: 'var(--text-secondary)',
                  fontSize: '9px',
                  cursor: 'pointer',
                }}
              >
                CANCEL
              </button>
            </div>
          </div>
        ) : (
          <div
            onClick={() => setIsEditing(true)}
            style={{
              padding: '6px 8px',
              background: 'var(--panel-hollow)',
              border: '1px solid var(--border)',
              borderRadius: '3px',
              cursor: 'pointer',
              marginBottom: '8px',
            }}
          >
            <div style={{
              fontSize: '9px',
              color: prompt ? 'var(--text-primary)' : 'var(--text-tertiary)',
              fontStyle: prompt ? 'normal' : 'italic',
            }}>
              {prompt || 'Click to describe sound...'}
            </div>
          </div>
        )}

        <SliderControl
          nodeId={nodeId}
          paramId="strength"
          label="Strength"
          value={strength}
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
          <div className="node-level-fill" style={{ width: `${strength * 100}%` }} />
        </div>
        <div className={`node-status-dot ${prompt ? 'active' : ''}`} />
      </div>
    </div>
  );
}
