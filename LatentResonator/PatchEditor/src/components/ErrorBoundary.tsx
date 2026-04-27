import { Component, ReactNode } from 'react';

interface Props {
  children: ReactNode;
  fallback?: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
  errorInfo: string;
}

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false, error: null, errorInfo: '' };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error, errorInfo: '' };
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    const info = errorInfo.componentStack || 'No stack trace';
    this.setState({ errorInfo: info });
    
    // Log to console for Safari debugging
    console.error('[ERROR BOUNDARY] React Error:', error);
    console.error('[ERROR BOUNDARY] Component Stack:', info);
    
    // Also try to send to Swift if bridge is available
    try {
      if ((window as any).webkit?.messageHandlers?.bridge) {
        (window as any).webkit.messageHandlers.bridge.postMessage({
          action: 'client.error',
          error: error.message,
          stack: info
        });
      }
    } catch (e) {
      // Ignore bridge errors
    }
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={{
          padding: '20px',
          backgroundColor: '#ff3333',
          color: 'white',
          fontFamily: 'monospace',
          fontSize: '12px',
          maxHeight: '100vh',
          overflow: 'auto'
        }}>
          <h2>🔴 Patch Editor Error</h2>
          <p><strong>Error:</strong> {this.state.error?.message}</p>
          <pre style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
            {this.state.errorInfo}
          </pre>
          <button 
            onClick={() => this.setState({ hasError: false, error: null, errorInfo: '' })}
            style={{
              marginTop: '20px',
              padding: '10px 20px',
              fontSize: '14px',
              cursor: 'pointer'
            }}
          >
            Try to Recover
          </button>
        </div>
      );
    }

    return this.props.children;
  }
}
