import { useState } from 'react';
import { GraphNodeData } from '../types';
import './NodeContextMenu.css';

export type ContextMenuAction =
  | { type: 'expose'; nodeId: string; paramId: string; label: string; controlType: 'knob' | 'fader' | 'toggle' | 'button' }
  | { type: 'hide'; nodeId: string; paramId: string; controlId: string }
  | { type: 'macro'; nodeId: string; sourceParamId: string; targetNodeId: string; targetParamId: string; curve: string }
  | { type: 'delete'; nodeId: string }
  | { type: 'duplicate'; nodeId: string }
  | { type: 'rename'; nodeId: string; newName: string }
  | { type: 'reset'; nodeId: string };

interface ExposedParamInfo {
  paramId: string;
  controlId: string;
  label: string;
}

interface NodeContextMenuProps {
  x: number;
  y: number;
  node: GraphNodeData;
  exposedParams?: string[];
  exposedParamInfo?: ExposedParamInfo[];  // Detailed info for hide functionality
  onAction: (action: ContextMenuAction) => void;
  onClose: () => void;
}

const CONTROL_TYPES = [
  { id: 'knob', label: 'Knob', icon: '◉', description: 'Rotary control (0-1)' },
  { id: 'fader', label: 'Fader', icon: '▮', description: 'Linear slider' },
  { id: 'toggle', label: 'Toggle', icon: '⊘', description: 'On/off switch' },
  { id: 'button', label: 'Button', icon: '⌁', description: 'Momentary trigger' },
] as const;

const SCALING_CURVES = [
  { id: 'linear', label: 'Linear', description: '1:1 mapping' },
  { id: 'exponential', label: 'Exponential', description: 'Faster at high values' },
  { id: 'logarithmic', label: 'Logarithmic', description: 'Slower at low values' },
  { id: 'inverted', label: 'Inverted', description: '1 - value' },
  { id: 'sCurve', label: 'S-Curve', description: 'Smooth transition' },
] as const;

type MenuView = 'main' | 'expose' | 'macro-source' | 'macro-target' | 'confirm-delete' | 'rename';

export function NodeContextMenu({ x, y, node, exposedParams = [], exposedParamInfo = [], onAction, onClose }: NodeContextMenuProps) {
  const [view, setView] = useState<MenuView>('main');
  const [selectedParam, setSelectedParam] = useState<string>('');
  const [customLabel, setCustomLabel] = useState('');
  const [selectedControlType, setSelectedControlType] = useState<'knob' | 'fader' | 'toggle' | 'button'>('knob');
  const [macroSourceParam, setMacroSourceParam] = useState<string>('');
  const [targetNodeId, setTargetNodeId] = useState('');
  const [targetParamId, setTargetParamId] = useState('');
  const [selectedCurve, setSelectedCurve] = useState('linear');
  const [newName, setNewName] = useState(node.displayName);

  const params = Object.keys(node.parameters || {});
  const availableParams = params.filter(p => !exposedParams.includes(p));

  // Clamp position to viewport
  const menuX = Math.min(x, window.innerWidth - 280);
  const menuY = Math.min(y, window.innerHeight - 400);

  const handleExpose = () => {
    const label = customLabel || selectedParam.toUpperCase();
    onAction({
      type: 'expose',
      nodeId: node.id,
      paramId: selectedParam,
      label,
      controlType: selectedControlType,
    });
    onClose();
  };

  const handleHide = (paramId: string, controlId: string) => {
    onAction({
      type: 'hide',
      nodeId: node.id,
      paramId,
      controlId,
    });
    onClose();
  };

  const handleMacroCreate = () => {
    onAction({
      type: 'macro',
      nodeId: node.id,
      sourceParamId: macroSourceParam,
      targetNodeId,
      targetParamId,
      curve: selectedCurve,
    });
    onClose();
  };

  const handleDelete = () => {
    onAction({ type: 'delete', nodeId: node.id });
    onClose();
  };

  const handleRename = () => {
    onAction({ type: 'rename', nodeId: node.id, newName: newName.trim() || node.displayName });
    onClose();
  };

  const handleReset = () => {
    onAction({ type: 'reset', nodeId: node.id });
    onClose();
  };

  // MAIN MENU VIEW
  if (view === 'main') {
    return (
      <div className="node-context-menu" style={{ left: menuX, top: menuY }}>
        <div className="context-menu-header">
          <div className="context-menu-node-type">{node.type.toUpperCase()}</div>
          <div className="context-menu-node-name">{node.displayName}</div>
        </div>

        <div className="context-menu-section">
          <div className="context-menu-section-title">Parameters</div>
          {params.length === 0 ? (
            <div className="context-menu-empty">No configurable parameters</div>
          ) : (
            <div className="context-menu-params">
              {params.map(param => {
                const isExposed = exposedParams.includes(param);
                const value = node.parameters[param];
                const displayValue = typeof value === 'number' ? value.toFixed(2) : String(value);

                return (
                  <div key={param} className={`context-menu-param ${isExposed ? 'exposed' : ''}`}>
                    <span className="param-name">{param}</span>
                    <span className="param-value">{displayValue}</span>
                    {isExposed && <span className="param-badge" title="Exposed to control panel">★</span>}
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {exposedParams.length > 0 && (
          <div className="context-menu-section">
            <div className="context-menu-section-title">Exposed Parameters (Click to Hide)</div>
            <div className="context-menu-params">
              {exposedParamInfo.map((info) => (
                <button
                  key={info.controlId}
                  className="context-menu-param hide-btn"
                  onClick={() => handleHide(info.paramId, info.controlId)}
                  title={`Hide ${info.label} from control panel`}
                >
                  <span className="param-name">★ {info.label}</span>
                  <span className="param-action">✕ Hide</span>
                </button>
              ))}
            </div>
          </div>
        )}

        <div className="context-menu-section">
          <div className="context-menu-section-title">Actions</div>
          <div className="context-menu-actions">
            {availableParams.length > 0 && (
              <button className="context-menu-btn primary" onClick={() => setView('expose')}>
                <span className="btn-icon">★</span>
                <span>Expose Parameter...</span>
                <span className="btn-hint">{availableParams.length} available</span>
              </button>
            )}

            {exposedParams.length > 0 && (
              <button className="context-menu-btn" onClick={() => setView('macro-source')}>
                <span className="btn-icon">⛓</span>
                <span>Create Macro Binding...</span>
                <span className="btn-hint">{exposedParams.length} sources</span>
              </button>
            )}

            <button className="context-menu-btn" onClick={() => setView('rename')}>
              <span className="btn-icon">✎</span>
              <span>Rename Node</span>
            </button>

            <button className="context-menu-btn" onClick={handleReset}>
              <span className="btn-icon">↺</span>
              <span>Reset to Defaults</span>
            </button>

            <div className="context-menu-divider" />

            <button className="context-menu-btn danger" onClick={() => setView('confirm-delete')}>
              <span className="btn-icon">✕</span>
              <span>Delete Node</span>
            </button>
          </div>
        </div>

        <button className="context-menu-close" onClick={onClose}>✕</button>
      </div>
    );
  }

  // EXPOSE PARAMETER VIEW
  if (view === 'expose') {
    return (
      <div className="node-context-menu expose-view" style={{ left: menuX, top: menuY }}>
        <div className="context-menu-header">
          <button className="back-btn" onClick={() => setView('main')}>←</button>
          <div className="context-menu-title">Expose Parameter</div>
        </div>

        <div className="context-menu-section">
          <div className="context-menu-section-title">Select Parameter</div>
          <div className="context-menu-param-list">
            {availableParams.map(param => (
              <button
                key={param}
                className={`param-select-btn ${selectedParam === param ? 'selected' : ''}`}
                onClick={() => {
                  setSelectedParam(param);
                  setCustomLabel(param.toUpperCase());
                }}
              >
                <span className="param-select-name">{param}</span>
                <span className="param-select-value">
                  {typeof node.parameters[param] === 'number'
                    ? (node.parameters[param] as number).toFixed(2)
                    : String(node.parameters[param])}
                </span>
              </button>
            ))}
          </div>
        </div>

        {selectedParam && (
          <>
            <div className="context-menu-section">
              <div className="context-menu-section-title">Control Label</div>
              <input
                type="text"
                className="context-menu-input"
                value={customLabel}
                onChange={(e) => setCustomLabel(e.target.value)}
                placeholder="Name shown in control panel"
              />
            </div>

            <div className="context-menu-section">
              <div className="context-menu-section-title">Control Type</div>
              <div className="control-type-grid">
                {CONTROL_TYPES.map(type => (
                  <button
                    key={type.id}
                    className={`control-type-btn ${selectedControlType === type.id ? 'selected' : ''}`}
                    onClick={() => setSelectedControlType(type.id)}
                    title={type.description}
                  >
                    <span className="control-type-icon">{type.icon}</span>
                    <span className="control-type-label">{type.label}</span>
                  </button>
                ))}
              </div>
            </div>

            <div className="context-menu-footer-actions">
              <button className="btn-secondary" onClick={() => setView('main')}>Cancel</button>
              <button className="btn-primary" onClick={handleExpose} disabled={!selectedParam}>
                Expose ★
              </button>
            </div>
          </>
        )}
      </div>
    );
  }

  // MACRO SOURCE SELECTION
  if (view === 'macro-source') {
    return (
      <div className="node-context-menu macro-view" style={{ left: menuX, top: menuY }}>
        <div className="context-menu-header">
          <button className="back-btn" onClick={() => setView('main')}>←</button>
          <div className="context-menu-title">Macro Binding - Source</div>
        </div>

        <div className="context-menu-section">
          <div className="context-menu-section-title">Select Exposed Control (Source)</div>
          <div className="context-menu-param-list">
            {exposedParams.map(param => (
              <button
                key={param}
                className={`param-select-btn ${macroSourceParam === param ? 'selected' : ''}`}
                onClick={() => {
                  setMacroSourceParam(param);
                  setView('macro-target');
                }}
              >
                <span className="param-select-name">★ {param}</span>
                <span className="param-select-value">
                  {typeof node.parameters[param] === 'number'
                    ? (node.parameters[param] as number).toFixed(2)
                    : String(node.parameters[param])}
                </span>
              </button>
            ))}
          </div>
        </div>
      </div>
    );
  }

  // MACRO TARGET SELECTION
  if (view === 'macro-target') {
    return (
      <div className="node-context-menu macro-view" style={{ left: menuX, top: menuY }}>
        <div className="context-menu-header">
          <button className="back-btn" onClick={() => setView('macro-source')}>←</button>
          <div className="context-menu-title">Macro Binding - Target</div>
        </div>

        <div className="context-menu-section">
          <div className="context-menu-section-title">Target Node ID</div>
          <input
            type="text"
            className="context-menu-input"
            value={targetNodeId}
            onChange={(e) => setTargetNodeId(e.target.value)}
            placeholder="Enter target node ID..."
          />
        </div>

        <div className="context-menu-section">
          <div className="context-menu-section-title">Target Parameter</div>
          <input
            type="text"
            className="context-menu-input"
            value={targetParamId}
            onChange={(e) => setTargetParamId(e.target.value)}
            placeholder="e.g., frequency, cutoff, mix..."
          />
        </div>

        <div className="context-menu-section">
          <div className="context-menu-section-title">Scaling Curve</div>
          <div className="curve-list">
            {SCALING_CURVES.map(curve => (
              <button
                key={curve.id}
                className={`curve-btn ${selectedCurve === curve.id ? 'selected' : ''}`}
                onClick={() => setSelectedCurve(curve.id)}
              >
                <span className="curve-name">{curve.label}</span>
                <span className="curve-desc">{curve.description}</span>
              </button>
            ))}
          </div>
        </div>

        <div className="context-menu-footer-actions">
          <button className="btn-secondary" onClick={() => setView('macro-source')}>Back</button>
          <button
            className="btn-primary"
            onClick={handleMacroCreate}
            disabled={!targetNodeId || !targetParamId}
          >
            Create Binding ⛓
          </button>
        </div>
      </div>
    );
  }

  // CONFIRM DELETE
  if (view === 'confirm-delete') {
    return (
      <div className="node-context-menu confirm-view" style={{ left: menuX, top: menuY }}>
        <div className="context-menu-header warning">
          <div className="context-menu-title">⚠ Delete Node?</div>
        </div>

        <div className="context-menu-section">
          <p className="confirm-text">
            This will permanently delete <strong>{node.displayName}</strong> and all its connections.
          </p>
        </div>

        <div className="context-menu-footer-actions">
          <button className="btn-secondary" onClick={() => setView('main')}>Cancel</button>
          <button className="btn-danger" onClick={handleDelete}>Delete Node</button>
        </div>
      </div>
    );
  }

  // RENAME VIEW
  if (view === 'rename') {
    return (
      <div className="node-context-menu rename-view" style={{ left: menuX, top: menuY }}>
        <div className="context-menu-header">
          <button className="back-btn" onClick={() => setView('main')}>←</button>
          <div className="context-menu-title">Rename Node</div>
        </div>

        <div className="context-menu-section">
          <div className="context-menu-section-title">New Name</div>
          <input
            type="text"
            className="context-menu-input"
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="Enter new name..."
            autoFocus
            onKeyDown={(e) => {
              if (e.key === 'Enter') handleRename();
              if (e.key === 'Escape') setView('main');
            }}
          />
        </div>

        <div className="context-menu-footer-actions">
          <button className="btn-secondary" onClick={() => setView('main')}>Cancel</button>
          <button className="btn-primary" onClick={handleRename}>Rename ✎</button>
        </div>
      </div>
    );
  }

  return null;
}
