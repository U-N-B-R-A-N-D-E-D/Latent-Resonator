import { Handle, Position, NodeProps } from '@xyflow/react';
import { GraphNodeData } from '../types';
import { useState, useCallback } from 'react';
import { bridge } from '../bridge';

/**
 * 3-Phase Prompt Engine Node (Whitepaper §4.2.2)
 *
 * Evolutionary prompt system driven by spectral flatness:
 * - Phase 1 (Harmonic): Low flatness - tonal, structured
 * - Phase 2 (Transitional): Medium flatness - evolving, drifting
 * - Phase 3 (Chaotic): High flatness - granular, entropic
 */

interface PhaseConfig {
  id: 1 | 2 | 3;
  label: string;
  color: string;
  defaultPrompt: string;
}

const PHASES: PhaseConfig[] = [
  { id: 1, label: 'HARMONIC', color: '#10b981', defaultPrompt: 'ferrofluid, subharmonic, warm resonance' },
  { id: 2, label: 'TRANSITION', color: '#f59e0b', defaultPrompt: 'spectral drift, evolving texture' },
  { id: 3, label: 'CHAOTIC', color: '#ef4444', defaultPrompt: 'granular chaos, noise as structure' },
];

export function PromptEngineNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;

  // 3-phase parameters
  const phase1 = (nodeData.parameters?.phase1Prompt as string) ?? '';
  const phase2 = (nodeData.parameters?.phase2Prompt as string) ?? '';
  const phase3 = (nodeData.parameters?.phase3Prompt as string) ?? '';
  const threshold12 = (nodeData.parameters?.phase1to2Threshold as number) ?? 0.35;
  const threshold23 = (nodeData.parameters?.phase2to3Threshold as number) ?? 0.65;
  const currentFlatness = (nodeData.parameters?.currentFlatness as number) ?? 0.0;

  // UI state
  const [isExpanded, setIsExpanded] = useState(false);
  const [editingPhase, setEditingPhase] = useState<1 | 2 | 3 | null>(null);
  const [editText, setEditText] = useState('');

  // Determine current active phase
  const currentPhase = currentFlatness < threshold12 ? 1 : currentFlatness < threshold23 ? 2 : 3;

  // Get effective prompt based on flatness
  const getEffectivePrompt = () => {
    if (currentFlatness < threshold12) return phase1 || PHASES[0].defaultPrompt;
    if (currentFlatness < threshold23) {
      const t = (currentFlatness - threshold12) / (threshold23 - threshold12);
      return t < 0.5 ? phase1 || PHASES[0].defaultPrompt : phase2 || PHASES[1].defaultPrompt;
    }
    return phase3 || PHASES[2].defaultPrompt;
  };

  const handleSavePhase = useCallback((phase: 1 | 2 | 3) => {
    const paramKey = phase === 1 ? 'phase1Prompt' : phase === 2 ? 'phase2Prompt' : 'phase3Prompt';
    bridge.setParameter(nodeId, paramKey, editText);
    setEditingPhase(null);
  }, [nodeId, editText]);

  const startEditing = (phase: 1 | 2 | 3) => {
    const text = phase === 1 ? phase1 : phase === 2 ? phase2 : phase3;
    setEditText(text);
    setEditingPhase(phase);
  };

  return (
    <div className="react-flow__node-default node-category-neural" style={{ minWidth: '220px' }}>
      <div className="node-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <span>{nodeData.displayName || 'PROMPT ENGINE'}</span>
        <button
          onClick={() => setIsExpanded(!isExpanded)}
          style={{
            background: 'none',
            border: 'none',
            color: 'var(--text-secondary)',
            cursor: 'pointer',
            fontSize: '10px',
            padding: '2px 4px',
          }}
        >
          {isExpanded ? '▼' : '▶'}
        </button>
      </div>

      {isExpanded ? (
        <div className="node-body nodrag" style={{ padding: '8px' }}>
          {/* Phase indicators */}
          <div style={{ display: 'flex', gap: '4px', marginBottom: '8px' }}>
            {PHASES.map((p) => (
              <div
                key={p.id}
                style={{
                  flex: 1,
                  padding: '4px',
                  background: currentPhase === p.id ? p.color : 'var(--panel-hollow)',
                  borderRadius: '3px',
                  textAlign: 'center',
                  fontSize: '8px',
                  fontWeight: currentPhase === p.id ? 'bold' : 'normal',
                  color: currentPhase === p.id ? '#000' : 'var(--text-secondary)',
                }}
              >
                {p.label}
              </div>
            ))}
          </div>

          {/* Phase editors */}
          {PHASES.map((p) => {
            const text = p.id === 1 ? phase1 : p.id === 2 ? phase2 : phase3;
            const isEditing = editingPhase === p.id;

            return (
              <div
                key={p.id}
                style={{
                  marginBottom: '8px',
                  padding: '6px',
                  background: 'var(--panel-hollow)',
                  borderRadius: '3px',
                  borderLeft: `3px solid ${p.color}`,
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '4px' }}>
                  <span style={{ fontSize: '9px', color: p.color, fontWeight: 'bold' }}>
                    PHASE {p.id}
                  </span>
                  {!isEditing && (
                    <button
                      onClick={() => startEditing(p.id)}
                      style={{
                        fontSize: '8px',
                        padding: '2px 6px',
                        background: 'var(--surface-subtle)',
                        border: '1px solid var(--border)',
                        borderRadius: '2px',
                        color: 'var(--text-secondary)',
                        cursor: 'pointer',
                      }}
                    >
                      EDIT
                    </button>
                  )}
                </div>

                {isEditing ? (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
                    <textarea
                      value={editText}
                      onChange={(e) => setEditText(e.target.value)}
                      style={{
                        width: '100%',
                        minHeight: '50px',
                        background: 'var(--titanio-base)',
                        border: `1px solid ${p.color}`,
                        borderRadius: '3px',
                        color: 'var(--text-primary)',
                        fontFamily: 'inherit',
                        fontSize: '9px',
                        padding: '4px',
                        resize: 'vertical',
                      }}
                      placeholder={`Enter phase ${p.id} prompt...`}
                      autoFocus
                    />
                    <div style={{ display: 'flex', gap: '4px' }}>
                      <button
                        onClick={() => handleSavePhase(p.id)}
                        style={{
                          flex: 1,
                          padding: '3px 6px',
                          background: p.color,
                          border: 'none',
                          borderRadius: '2px',
                          color: '#000',
                          fontSize: '8px',
                          fontWeight: 600,
                          cursor: 'pointer',
                        }}
                      >
                        SAVE
                      </button>
                      <button
                        onClick={() => setEditingPhase(null)}
                        style={{
                          flex: 1,
                          padding: '3px 6px',
                          background: 'var(--panel-hollow)',
                          border: '1px solid var(--border)',
                          borderRadius: '2px',
                          color: 'var(--text-secondary)',
                          fontSize: '8px',
                          cursor: 'pointer',
                        }}
                      >
                        CANCEL
                      </button>
                    </div>
                  </div>
                ) : (
                  <div
                    onClick={() => startEditing(p.id)}
                    style={{
                      fontSize: '9px',
                      color: text ? 'var(--text-primary)' : 'var(--text-tertiary)',
                      fontStyle: text ? 'normal' : 'italic',
                      cursor: 'pointer',
                      minHeight: '24px',
                      lineHeight: '1.4',
                    }}
                  >
                    {text || `Click to set phase ${p.id} prompt...`}
                  </div>
                )}
              </div>
            );
          })}

          {/* Threshold controls */}
          <div style={{ marginTop: '8px', padding: '6px', background: 'var(--titanio-base)', borderRadius: '3px' }}>
            <div style={{ fontSize: '8px', color: 'var(--text-secondary)', marginBottom: '6px', fontWeight: 'bold' }}>
              PHASE THRESHOLDS
            </div>
            <div style={{ marginBottom: '6px' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '8px', color: 'var(--text-tertiary)', marginBottom: '2px' }}>
                <span>1→2 Threshold</span>
                <span>{threshold12.toFixed(2)}</span>
              </div>
              <input
                type="range"
                min="0"
                max="1"
                step="0.05"
                value={threshold12}
                onChange={(e) => bridge.setParameter(nodeId, 'phase1to2Threshold', parseFloat(e.target.value))}
                style={{ width: '100%', height: '4px' }}
              />
            </div>
            <div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '8px', color: 'var(--text-tertiary)', marginBottom: '2px' }}>
                <span>2→3 Threshold</span>
                <span>{threshold23.toFixed(2)}</span>
              </div>
              <input
                type="range"
                min="0"
                max="1"
                step="0.05"
                value={threshold23}
                onChange={(e) => bridge.setParameter(nodeId, 'phase2to3Threshold', parseFloat(e.target.value))}
                style={{ width: '100%', height: '4px' }}
              />
            </div>
          </div>
        </div>
      ) : (
        /* Collapsed view */
        <div className="node-body" style={{ padding: '8px' }}>
          <div style={{ display: 'flex', gap: '4px', marginBottom: '6px' }}>
            {PHASES.map((p) => (
              <div
                key={p.id}
                style={{
                  flex: 1,
                  height: '4px',
                  background: currentPhase >= p.id ? p.color : 'var(--panel-hollow)',
                  borderRadius: '2px',
                }}
              />
            ))}
          </div>
          <div style={{ fontSize: '9px', color: 'var(--text-secondary)', marginBottom: '4px' }}>
            Active: <span style={{ color: PHASES[currentPhase - 1]?.color, fontWeight: 'bold' }}>
              {PHASES[currentPhase - 1]?.label}
            </span>
          </div>
          <div style={{
            fontSize: '8px',
            color: 'var(--text-tertiary)',
            fontStyle: 'italic',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}>
            {getEffectivePrompt()}
          </div>
        </div>
      )}

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

      {/* Telemetry */}
      <div className="node-telemetry">
        <div className="node-level-meter">
          <div
            className="node-level-fill"
            style={{
              width: `${Math.min(100, currentFlatness * 100)}%`,
              background: PHASES[currentPhase - 1]?.color || 'var(--signal-text)',
            }}
          />
        </div>
        <div
          className="node-status-dot"
          style={{
            background: PHASES[currentPhase - 1]?.color || 'var(--text-tertiary)',
          }}
        />
      </div>
    </div>
  );
}
