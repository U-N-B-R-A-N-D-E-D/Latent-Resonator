import { useState, useEffect, useRef } from 'react';
import './NodeMenu.css';

export interface NodeCategory {
  name: string;
  nodes: NodeType[];
}

export interface NodeType {
  id: string;
  label: string;
  description?: string;
}

interface NodeMenuProps {
  x: number;
  y: number;
  onSelect: (nodeType: string) => void;
  onClose: () => void;
}

const NODE_CATEGORIES: NodeCategory[] = [
  {
    name: 'SOURCES',
    nodes: [
      { id: 'oscillator', label: 'Oscillator', description: 'Sine/saw/square wave generator' },
      { id: 'noise', label: 'Noise', description: 'White/pink noise source' },
      { id: 'audio_input', label: 'Audio Input', description: 'System audio input' },
      { id: 'silence', label: 'Silence', description: 'Silent source' },
    ],
  },
  {
    name: 'ROUTING',
    nodes: [
      { id: 'mixer', label: 'Mixer', description: 'Mix multiple audio signals' },
      { id: 'passthrough', label: 'Passthrough', description: 'Direct signal pass' },
      { id: 'master_output', label: 'Master Output', description: 'Final audio output' },
    ],
  },
  {
    name: 'SPECTRAL',
    nodes: [
      { id: 'fft_analysis', label: 'FFT Analysis', description: 'Frequency domain conversion' },
      { id: 'semantic_eq', label: 'Semantic EQ', description: 'Neural spectral shaping' },
      { id: 'spectral_saturation', label: 'Saturation', description: 'Frequency-dependent saturation' },
      { id: 'spectral_noise', label: 'Spectral Noise', description: 'Frequency-based noise injection' },
      { id: 'spectral_memory', label: 'Memory', description: 'Spectral frame delay' },
      { id: 'spectral_granularity', label: 'Granularity', description: 'Frequency resolution control' },
      { id: 'spectral_freeze', label: 'Freeze', description: 'Freeze spectral content' },
      { id: 'ifft_synthesis', label: 'IFFT Synthesis', description: 'Time domain conversion' },
    ],
  },
  {
    name: 'EFFECTS',
    nodes: [
      { id: 'ladder_filter', label: 'Ladder Filter', description: 'Moog-style resonant filter' },
      { id: 'comb_filter', label: 'Comb Filter', description: 'Delay-based filtering' },
      { id: 'tunable_resonator', label: 'Resonator', description: 'Tunable resonant filter' },
      { id: 'bit_crusher', label: 'Bit Crusher', description: 'Sample rate/bit depth reduction' },
      { id: 'waveshaper', label: 'Waveshaper', description: 'Nonlinear distortion' },
      { id: 'delay_line', label: 'Delay', description: 'Time delay buffer' },
    ],
  },
  {
    name: 'NEURAL',
    nodes: [
      { id: 'ace_step_inference', label: 'ACE Step', description: 'Single inference step' },
      { id: 'prompt_engine', label: 'Prompt Engine', description: 'Text-driven modulation' },
      { id: 'feedback_loop', label: 'Feedback Loop', description: 'Recursive neural processing' },
    ],
  },
  {
    name: 'CONTROL',
    nodes: [
      { id: 'agitation', label: 'Agitation', description: 'Chaos-based modulation' },
      { id: 'peak', label: 'Peak', description: 'Peak detection' },
      { id: 'manual_control', label: 'Manual Control', description: 'Manual CV output' },
      { id: 'step_sequencer', label: 'Step Sequencer', description: '16-step pattern generator' },
      { id: 'markov_sequencer', label: 'Markov Sequencer', description: 'Probabilistic sequences' },
    ],
  },
  {
    name: 'ANALYSIS',
    nodes: [
      { id: 'spectral_analyzer', label: 'Spectral Analyzer', description: 'Audio → control signals' },
    ],
  },
];

export function NodeMenu({ x, y, onSelect, onClose }: NodeMenuProps) {
  const [filter, setFilter] = useState('');
  const [selectedIndex, setSelectedIndex] = useState(0);
  const menuRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  // Filter nodes based on search
  const filteredCategories = NODE_CATEGORIES.map(category => ({
    ...category,
    nodes: category.nodes.filter(
      node =>
        node.label.toLowerCase().includes(filter.toLowerCase()) ||
        node.id.toLowerCase().includes(filter.toLowerCase()) ||
        (node.description?.toLowerCase().includes(filter.toLowerCase()) ?? false)
    ),
  })).filter(category => category.nodes.length > 0);

  // Flatten for keyboard navigation
  const allFilteredNodes = filteredCategories.flatMap(cat => cat.nodes);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        onClose();
      }
    };

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose();
      } else if (e.key === 'ArrowDown') {
        e.preventDefault();
        setSelectedIndex(prev => Math.min(prev + 1, allFilteredNodes.length - 1));
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        setSelectedIndex(prev => Math.max(prev - 1, 0));
      } else if (e.key === 'Enter') {
        e.preventDefault();
        if (allFilteredNodes[selectedIndex]) {
          onSelect(allFilteredNodes[selectedIndex].id);
        }
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    document.addEventListener('keydown', handleKeyDown);

    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
      document.removeEventListener('keydown', handleKeyDown);
    };
  }, [onClose, onSelect, selectedIndex, allFilteredNodes]);

  let globalIndex = 0;

  return (
    <div
      ref={menuRef}
      className="node-menu"
      style={{
        position: 'fixed',
        left: `${x}px`,
        top: `${y}px`,
      }}
    >
      <div className="node-menu-header">
        <input
          ref={inputRef}
          type="text"
          placeholder="Search nodes..."
          value={filter}
          onChange={e => {
            setFilter(e.target.value);
            setSelectedIndex(0);
          }}
          className="node-menu-search"
        />
      </div>

      <div className="node-menu-content">
        {filteredCategories.length === 0 ? (
          <div className="node-menu-empty">No nodes found</div>
        ) : (
          filteredCategories.map((category, catIndex) => (
            <div key={catIndex} className="node-menu-category">
              <div className="node-menu-category-name">{category.name}</div>
              {category.nodes.map((node) => {
                const currentIndex = globalIndex++;
                const isSelected = currentIndex === selectedIndex;

                return (
                  <div
                    key={node.id}
                    className={`node-menu-item ${isSelected ? 'selected' : ''}`}
                    onClick={() => onSelect(node.id)}
                    onMouseEnter={() => setSelectedIndex(currentIndex)}
                  >
                    <div className="node-menu-item-label">{node.label}</div>
                    {node.description && (
                      <div className="node-menu-item-description">{node.description}</div>
                    )}
                  </div>
                );
              })}
            </div>
          ))
        )}
      </div>

      <div className="node-menu-footer">
        ↑↓ Navigate • Enter Select • Esc Close
      </div>
    </div>
  );
}
