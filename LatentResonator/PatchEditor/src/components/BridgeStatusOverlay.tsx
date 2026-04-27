import { useState, useEffect } from 'react';
import { BridgeStatus } from '../types';
import { bridge } from '../bridge';

export function BridgeStatusOverlay() {
  const [status, setStatus] = useState<BridgeStatus | null>(null);
  const [isExpanded, setIsExpanded] = useState(false);

  useEffect(() => {
    const handleStatus = (data: BridgeStatus) => {
      setStatus(data);
    };

    bridge.on('bridge.status', handleStatus);

    // Request initial status
    bridge.send({ action: 'bridge.getStatus' });

    return () => {
      bridge.off('bridge.status', handleStatus);
    };
  }, []);

  if (!status) {
    return (
      <div style={styles.container}>
        <div style={{ ...styles.dot, backgroundColor: '#666' }} />
        <span style={styles.text}>Bridge: Unknown</span>
      </div>
    );
  }

  const getStatusColor = () => {
    switch (status.status) {
      case 'MODEL_LOADED':
        return '#00ff88'; // Green - ready
      case 'CONNECTED':
        return '#00ccff'; // Cyan - connected but no model
      case 'CONNECTING':
      case 'RECOVERING':
        return '#ffaa00'; // Orange - in progress
      case 'ERROR':
        return '#ff4444'; // Red - error
      case 'DISCONNECTED':
      default:
        return '#666666'; // Gray - disconnected
    }
  };

  const getStatusText = () => {
    switch (status.status) {
      case 'MODEL_LOADED':
        return 'AI Ready';
      case 'CONNECTED':
        return 'Connected (No Model)';
      case 'CONNECTING':
        return 'Connecting...';
      case 'RECOVERING':
        return `Reconnecting (${status.consecutiveFailures} failures)`;
      case 'ERROR':
        return status.lastError?.substring(0, 30) || 'Error';
      case 'DISCONNECTED':
        return 'Disconnected';
      default:
        return status.status;
    }
  };

  return (
    <div
      style={{
        ...styles.container,
        backgroundColor: isExpanded ? 'rgba(20, 21, 22, 0.95)' : 'rgba(10, 11, 12, 0.8)',
        cursor: 'pointer',
      }}
      onClick={() => setIsExpanded(!isExpanded)}
    >
      <div style={{ ...styles.dot, backgroundColor: getStatusColor() }} />
      <span style={styles.text}>{getStatusText()}</span>

      {isExpanded && (
        <div style={styles.details} onClick={(e) => e.stopPropagation()}>
          <div style={styles.detailRow}>
            <span style={styles.detailLabel}>Status:</span>
            <span style={{ ...styles.detailValue, color: getStatusColor() }}>
              {status.status}
            </span>
          </div>
          <div style={styles.detailRow}>
            <span style={styles.detailLabel}>Model:</span>
            <span style={styles.detailValue}>
              {status.isModelLoaded ? status.remoteModelType : 'Not loaded'}
            </span>
          </div>
          <div style={styles.detailRow}>
            <span style={styles.detailLabel}>Device:</span>
            <span style={styles.detailValue}>{status.remoteDevice}</span>
          </div>
          <div style={styles.detailRow}>
            <span style={styles.detailLabel}>Inferences:</span>
            <span style={styles.detailValue}>{status.remoteInferenceCount}</span>
          </div>
          {status.consecutiveFailures > 0 && (
            <div style={styles.detailRow}>
              <span style={styles.detailLabel}>Failures:</span>
              <span style={{ ...styles.detailValue, color: '#ff4444' }}>
                {status.consecutiveFailures}
              </span>
            </div>
          )}
          {status.lastError && (
            <div style={styles.errorRow}>
              <span style={styles.detailLabel}>Last Error:</span>
              <span style={{ ...styles.detailValue, color: '#ff4444', fontSize: '10px' }}>
                {status.lastError}
              </span>
            </div>
          )}
          <div style={styles.helpText}>
            Click to {isExpanded ? 'collapse' : 'expand'}
          </div>
        </div>
      )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    position: 'fixed',
    top: '12px',
    right: '12px',
    zIndex: 1000,
    display: 'flex',
    alignItems: 'center',
    gap: '8px',
    padding: '8px 12px',
    borderRadius: '4px',
    border: '1px solid rgba(255, 255, 255, 0.1)',
    fontFamily: 'Fira Code, monospace',
    fontSize: '11px',
    color: '#ccc',
    transition: 'all 0.2s ease',
    backdropFilter: 'blur(4px)',
  },
  dot: {
    width: '8px',
    height: '8px',
    borderRadius: '50%',
    boxShadow: '0 0 4px currentColor',
    transition: 'background-color 0.3s ease',
  },
  text: {
    fontWeight: 500,
    letterSpacing: '0.3px',
  },
  details: {
    position: 'absolute',
    top: '100%',
    right: '0',
    marginTop: '8px',
    padding: '12px',
    minWidth: '200px',
    backgroundColor: 'rgba(15, 16, 17, 0.98)',
    borderRadius: '4px',
    border: '1px solid rgba(255, 255, 255, 0.15)',
    boxShadow: '0 4px 20px rgba(0, 0, 0, 0.5)',
  },
  detailRow: {
    display: 'flex',
    justifyContent: 'space-between',
    gap: '16px',
    marginBottom: '6px',
    fontSize: '10px',
  },
  errorRow: {
    display: 'flex',
    flexDirection: 'column',
    gap: '4px',
    marginTop: '8px',
    paddingTop: '8px',
    borderTop: '1px solid rgba(255, 68, 68, 0.3)',
    fontSize: '10px',
  },
  detailLabel: {
    color: '#888',
  },
  detailValue: {
    color: '#ccc',
    fontWeight: 500,
  },
  helpText: {
    marginTop: '10px',
    fontSize: '9px',
    color: '#666',
    textAlign: 'center',
    fontStyle: 'italic',
  },
};
