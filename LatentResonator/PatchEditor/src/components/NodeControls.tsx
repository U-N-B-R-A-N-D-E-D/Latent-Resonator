/**
 * Node Control Components
 * Reusable control components for node parameters
 * Envion-inspired design with rotary knobs and proper drag isolation
 * v2.0 - Fixed sticky knob behavior with robust pointer handling
 */

import { useCallback, useState, useRef, useEffect, useMemo } from 'react';
import { bridge } from '../bridge';

// === Knob Control (Envion-style rotary knob) ===
// v2.0 - Completely rewritten for robust drag behavior

interface KnobControlProps {
  nodeId: string;
  paramId: string;
  label: string;
  value: number;
  min: number;
  max: number;
  step?: number;
  size?: 'sm' | 'md' | 'lg';
  displayFormat?: (v: number) => string;
  onChange?: (value: number) => void;
  sensitivity?: number; // pixels per full range - lower = more sensitive
}

export function KnobControl({
  nodeId,
  paramId,
  label,
  value,
  min,
  max,
  step = 0.01,
  size = 'md',
  displayFormat = (v) => v.toFixed(2),
  onChange,
  sensitivity: sensitivityProp
}: KnobControlProps) {
  // Calculate sensitivity based on range and size
  const sensitivity = useMemo(() => {
    if (sensitivityProp) return sensitivityProp;
    const baseSensitivity = size === 'lg' ? 120 : size === 'sm' ? 180 : 150;
    return (max - min) / baseSensitivity;
  }, [max, min, size, sensitivityProp]);

  // Refs for drag state - using refs to avoid re-renders during drag
  const isDraggingRef = useRef(false);
  const startYRef = useRef(0);
  const startValueRef = useRef(0);
  const pointerIdRef = useRef<number | null>(null);
  const rafRef = useRef<number | null>(null);
  const pendingValueRef = useRef<number | null>(null);

  // UI state
  const [isDragging, setIsDragging] = useState(false);
  const [isHovered, setIsHovered] = useState(false);

  // Calculate knob geometry
  const normalizedValue = useMemo(() => {
    const clamped = Math.max(min, Math.min(max, value));
    return (clamped - min) / (max - min);
  }, [value, min, max]);

  const angle = useMemo(() => -135 + normalizedValue * 270, [normalizedValue]);

  const sizePx = useMemo(() => ({
    sm: 36,
    md: 48,
    lg: 60
  })[size], [size]);

  const { radius, circumference, arcLength, strokeDashoffset } = useMemo(() => {
    const strokeWidth = size === 'sm' ? 3 : size === 'md' ? 4 : 5;
    const r = (sizePx - strokeWidth) / 2 - 2;
    const c = 2 * Math.PI * r;
    const al = c * 0.75;
    const sd = c - (normalizedValue * al);
    return { radius: r, circumference: c, arcLength: al, strokeDashoffset: sd };
  }, [sizePx, size, normalizedValue]);

  // Cleanup function
  const cleanupDrag = useCallback(() => {
    isDraggingRef.current = false;
    setIsDragging(false);

    if (rafRef.current !== null) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }

    pendingValueRef.current = null;
    pointerIdRef.current = null;
  }, []);

  // Handle pointer down
  const handlePointerDown = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    // Prevent React Flow from starting node drag
    e.stopPropagation();
    e.preventDefault();

    // Capture pointer for smooth dragging outside element bounds
    const target = e.currentTarget;
    target.setPointerCapture(e.pointerId);
    pointerIdRef.current = e.pointerId;

    // Initialize drag state
    isDraggingRef.current = true;
    startYRef.current = e.clientY;
    startValueRef.current = value;

    setIsDragging(true);
  }, [value]);

  // Handle pointer move - using document events for reliability
  useEffect(() => {
    if (!isDragging) return;

    const handlePointerMove = (e: PointerEvent) => {
      if (!isDraggingRef.current) return;

      e.preventDefault();

      const deltaY = startYRef.current - e.clientY;
      const deltaValue = deltaY * sensitivity;
      let newValue = startValueRef.current + deltaValue;

      // Clamp to range
      newValue = Math.max(min, Math.min(max, newValue));

      // Quantize to step
      if (step > 0) {
        newValue = Math.round(newValue / step) * step;
      }

      // Debounce updates using RAF
      pendingValueRef.current = newValue;

      if (rafRef.current === null) {
        rafRef.current = requestAnimationFrame(() => {
          if (pendingValueRef.current !== null && isDraggingRef.current) {
            if (onChange) {
              onChange(pendingValueRef.current);
            } else {
              bridge.setParameter(nodeId, paramId, pendingValueRef.current);
            }
            pendingValueRef.current = null;
          }
          rafRef.current = null;
        });
      }
    };

    const handlePointerUp = (e: PointerEvent) => {
      if (!isDraggingRef.current) return;

      e.preventDefault();

      // Send final value
      if (pendingValueRef.current !== null) {
        if (onChange) {
          onChange(pendingValueRef.current);
        } else {
          bridge.setParameter(nodeId, paramId, pendingValueRef.current);
        }
      }

      cleanupDrag();
    };

    const handlePointerCancel = (e: PointerEvent) => {
      if (!isDraggingRef.current) return;
      e.preventDefault();
      cleanupDrag();
    };

    // Add global listeners for reliable drag behavior
    document.addEventListener('pointermove', handlePointerMove, { passive: false, capture: true });
    document.addEventListener('pointerup', handlePointerUp, { passive: false, capture: true });
    document.addEventListener('pointercancel', handlePointerCancel, { passive: false, capture: true });

    return () => {
      document.removeEventListener('pointermove', handlePointerMove, { capture: true });
      document.removeEventListener('pointerup', handlePointerUp, { capture: true });
      document.removeEventListener('pointercancel', handlePointerCancel, { capture: true });
    };
  }, [isDragging, sensitivity, min, max, step, nodeId, paramId, onChange, cleanupDrag]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (rafRef.current !== null) {
        cancelAnimationFrame(rafRef.current);
      }
    };
  }, []);

  const displayValue = displayFormat(value);

  return (
    <div className="node-knob-container nodrag nowheel">
      <div
        className={`node-knob ${isDragging ? 'dragging' : ''} ${isHovered ? 'hovered' : ''}`}
        data-size={size}
        style={{ width: sizePx, height: sizePx }}
        onPointerDown={handlePointerDown}
        onMouseEnter={() => setIsHovered(true)}
        onMouseLeave={() => !isDragging && setIsHovered(false)}
      >
        <svg width={sizePx} height={sizePx} viewBox={`0 0 ${sizePx} ${sizePx}`}>
          {/* Background track */}
          <circle
            cx={sizePx / 2}
            cy={sizePx / 2}
            r={radius}
            fill="none"
            stroke="rgba(0,0,0,0.5)"
            strokeWidth={size === 'sm' ? 3 : size === 'md' ? 4 : 5}
            strokeDasharray={`${arcLength} ${circumference - arcLength}`}
            strokeDashoffset={circumference * 0.125}
            transform={`rotate(135 ${sizePx / 2} ${sizePx / 2})`}
          />
          {/* Value arc */}
          <circle
            cx={sizePx / 2}
            cy={sizePx / 2}
            r={radius}
            fill="none"
            stroke="var(--neon-turquesa)"
            strokeWidth={size === 'sm' ? 3 : size === 'md' ? 4 : 5}
            strokeDasharray={`${arcLength} ${circumference - arcLength}`}
            strokeDashoffset={strokeDashoffset + circumference * 0.125}
            strokeLinecap="round"
            transform={`rotate(135 ${sizePx / 2} ${sizePx / 2})`}
            className="node-knob-value-arc"
          />
        </svg>
        {/* Indicator dot */}
        <div
          className="node-knob-indicator"
          style={{ transform: `rotate(${angle}deg)` }}
        >
          <div className="node-knob-dot" />
        </div>

        {/* Hover hint - shows interaction instruction */}
        {isHovered && !isDragging && (
          <div className="node-knob-hint">
            <span>↕</span>
          </div>
        )}

        {/* Active dragging overlay */}
        {isDragging && (
          <div className="node-knob-active-overlay" />
        )}
      </div>
      <div className="node-knob-label">{label}</div>
      <div className="node-knob-value">{displayValue}</div>
    </div>
  );
}

// === Slider Control ===
// v2.0 - Enhanced with better drag isolation and visual feedback

interface SliderControlProps {
  nodeId: string;
  paramId: string;
  label: string;
  value: number;
  min: number;
  max: number;
  step?: number;
  displayFormat?: (v: number) => string;
  variant?: 'compact' | 'horizontal';
}

export function SliderControl({
  nodeId,
  paramId,
  label,
  value,
  min,
  max,
  step = 1,
  displayFormat = (v) => v.toFixed(2),
  variant = 'compact'
}: SliderControlProps) {
  const handleSliderChange = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const newValue = parseFloat(e.target.value);
    bridge.setParameter(nodeId, paramId, newValue);
  }, [nodeId, paramId]);

  const handleInputChange = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const newValue = parseFloat(e.target.value);
    if (!isNaN(newValue)) {
      bridge.setParameter(nodeId, paramId, Math.max(min, Math.min(max, newValue)));
    }
  }, [nodeId, paramId, min, max]);

  const handleInputBlur = useCallback((e: React.FocusEvent<HTMLInputElement>) => {
    const newValue = parseFloat(e.target.value);
    if (isNaN(newValue)) {
      // Reset to current value if invalid
      e.target.value = displayFormat(value);
    }
  }, [value, displayFormat]);

  if (variant === 'horizontal') {
    return (
      <div className="node-control-row nodrag nowheel">
        <label>{label}</label>
        <input
          type="range"
          min={min}
          max={max}
          step={step}
          value={value}
          onChange={handleSliderChange}
          className="node-slider-compact"
        />
        <input
          type="number"
          value={displayFormat(value)}
          onChange={handleInputChange}
          onBlur={handleInputBlur}
          className="node-value-input"
          step={step}
        />
      </div>
    );
  }

  return (
    <div className="node-param-row nodrag nowheel">
      <label>{label}</label>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={handleSliderChange}
        className="node-param-slider"
      />
      <div className="node-param-value">{displayFormat(value)}</div>
    </div>
  );
}

// === Segmented Control ===
// v2.0 - Better visual feedback and keyboard navigation

interface SegmentControlProps {
  nodeId: string;
  paramId: string;
  label?: string;
  value: string;
  options: { value: string; label: string; icon?: string }[];
  size?: 'sm' | 'md';
}

export function SegmentControl({
  nodeId,
  paramId,
  label,
  value,
  options,
  size = 'md'
}: SegmentControlProps) {
  const handleSelect = useCallback((selectedValue: string) => {
    bridge.setParameter(nodeId, paramId, selectedValue);
  }, [nodeId, paramId]);

  return (
    <div className={`node-segment-wrapper nodrag nowheel ${size === 'sm' ? 'sm' : ''}`}>
      {label && <label className="node-segment-label">{label}</label>}
      <div className="node-segment-control">
        {options.map((opt) => (
          <button
            key={opt.value}
            className={`node-segment-btn ${value === opt.value ? 'selected' : ''}`}
            onClick={() => handleSelect(opt.value)}
            title={opt.label}
          >
            {opt.icon || opt.label}
          </button>
        ))}
      </div>
    </div>
  );
}

// === Toggle Control ===
// v2.0 - Improved states and visual feedback

interface ToggleControlProps {
  nodeId: string;
  paramId: string;
  label: string;
  value: boolean;
  size?: 'sm' | 'md';
  variant?: 'default' | 'accent';
}

export function ToggleControl({
  nodeId,
  paramId,
  label,
  value,
  size = 'md',
  variant = 'default'
}: ToggleControlProps) {
  const handleToggle = useCallback(() => {
    bridge.setParameter(nodeId, paramId, !value);
  }, [nodeId, paramId, value]);

  return (
    <button
      className={`node-toggle ${value ? 'active' : ''} ${size} ${variant}`}
      onClick={handleToggle}
      type="button"
    >
      {label}
    </button>
  );
}

// === Select Dropdown ===
// v2.0 - Better styling and accessibility

interface SelectControlProps {
  nodeId: string;
  paramId: string;
  label: string;
  value: string;
  options: { value: string; label: string; group?: string }[];
}

export function SelectControl({
  nodeId,
  paramId,
  label,
  value,
  options
}: SelectControlProps) {
  const handleChange = useCallback((e: React.ChangeEvent<HTMLSelectElement>) => {
    bridge.setParameter(nodeId, paramId, e.target.value);
  }, [nodeId, paramId]);

  // Group options if they have group property
  const groupedOptions = useMemo(() => {
    const groups: { [key: string]: typeof options } = {};
    const ungrouped: typeof options = [];

    options.forEach(opt => {
      if (opt.group) {
        if (!groups[opt.group]) groups[opt.group] = [];
        groups[opt.group].push(opt);
      } else {
        ungrouped.push(opt);
      }
    });

    return { groups, ungrouped };
  }, [options]);

  return (
    <div className="node-param-row nodrag nowheel">
      <label>{label}</label>
      <select value={value} onChange={handleChange} className="node-param-select">
        {groupedOptions.ungrouped.map((opt) => (
          <option key={opt.value} value={opt.value}>
            {opt.label}
          </option>
        ))}
        {Object.entries(groupedOptions.groups).map(([groupName, groupOpts]) => (
          <optgroup key={groupName} label={groupName}>
            {groupOpts.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </optgroup>
        ))}
      </select>
    </div>
  );
}

// === Step Sequencer Grid ===
// v2.0 - Better visual states and interaction

interface StepGridProps {
  steps: boolean[];
  currentStep: number;
  onStepToggle: (index: number) => void;
  variant?: '8' | '16';
}

export function StepGrid({ steps, currentStep, onStepToggle, variant = '8' }: StepGridProps) {
  const cols = variant === '16' ? 16 : 8;

  return (
    <div
      className="node-step-grid nodrag nowheel"
      style={{ gridTemplateColumns: `repeat(${cols}, 1fr)` }}
    >
      {steps.map((active, idx) => (
        <button
          key={idx}
          className={`node-step-btn ${active ? 'active' : ''} ${currentStep === idx ? 'current' : ''}`}
          onClick={() => onStepToggle(idx)}
          type="button"
          aria-label={`Step ${idx + 1} ${active ? 'active' : 'inactive'}`}
        />
      ))}
    </div>
  );
}

// === XY Pad Control ===
// v2.0 - Fixed pointer handling

interface XYPadProps {
  x: number;
  y: number;
  onChange: (x: number, y: number) => void;
  labelX?: string;
  labelY?: string;
}

export function XYPad({ x, y, onChange, labelX = 'X', labelY = 'Y' }: XYPadProps) {
  const isDraggingRef = useRef(false);
  const padRef = useRef<HTMLDivElement>(null);

  const updatePosition = useCallback((clientX: number, clientY: number) => {
    if (!padRef.current) return;

    const rect = padRef.current.getBoundingClientRect();
    const newX = (clientX - rect.left) / rect.width;
    const newY = 1 - (clientY - rect.top) / rect.height;

    onChange(
      Math.max(0, Math.min(1, newX)),
      Math.max(0, Math.min(1, newY))
    );
  }, [onChange]);

  const handlePointerDown = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    e.stopPropagation();
    e.preventDefault();

    isDraggingRef.current = true;
    if (padRef.current) {
      padRef.current.setPointerCapture(e.pointerId);
    }

    updatePosition(e.clientX, e.clientY);
  }, [updatePosition]);

  const handlePointerMove = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    if (!isDraggingRef.current) return;
    updatePosition(e.clientX, e.clientY);
  }, [updatePosition]);

  const handlePointerUp = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    isDraggingRef.current = false;
    if (padRef.current) {
      try {
        padRef.current.releasePointerCapture(e.pointerId);
      } catch {
        // Ignore if already released
      }
    }
  }, []);

  return (
    <div className="node-xypad-wrapper">
      <div
        ref={padRef}
        className="node-xypad nodrag nowheel"
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
      >
        {/* Grid lines for visual reference */}
        <div className="node-xypad-grid" />
        <div
          className="node-xypad-point"
          style={{ left: `${x * 100}%`, bottom: `${y * 100}%` }}
        />
      </div>
      <div className="node-xypad-labels">
        <span>{labelX}: {(x * 100).toFixed(0)}%</span>
        <span>{labelY}: {(y * 100).toFixed(0)}%</span>
      </div>
    </div>
  );
}

// === Node Container ===
// v2.0 - Improved category styling

interface NodeContainerProps {
  category: string;
  header: string;
  children: React.ReactNode;
  className?: string;
}

export function NodeContainer({ category, header, children, className = '' }: NodeContainerProps) {
  return (
    <div className={`react-flow__node-default node-category-${category} ${className}`}>
      <div className="node-header">{header}</div>
      <div className="node-body nodrag nowheel">{children}</div>
    </div>
  );
}

// === Tooltip Component ===
// v2.0 - New component for better UX

interface TooltipProps {
  content: string;
  children: React.ReactNode;
  position?: 'top' | 'bottom' | 'left' | 'right';
}

export function Tooltip({ content, children, position = 'top' }: TooltipProps) {
  const [isVisible, setIsVisible] = useState(false);

  return (
    <div
      className="node-tooltip-wrapper"
      onMouseEnter={() => setIsVisible(true)}
      onMouseLeave={() => setIsVisible(false)}
    >
      {children}
      {isVisible && (
        <div className={`node-tooltip node-tooltip-${position}`}>
          {content}
        </div>
      )}
    </div>
  );
}

// === Meter Component ===
// v2.0 - Visual level meter

interface MeterProps {
  value: number; // 0-1
  peak?: number; // 0-1
  orientation?: 'horizontal' | 'vertical';
  size?: 'sm' | 'md';
}

export function Meter({ value, peak = 0, orientation = 'horizontal', size = 'sm' }: MeterProps) {
  const percent = Math.max(0, Math.min(100, value * 100));
  const peakPercent = Math.max(0, Math.min(100, peak * 100));

  return (
    <div className={`node-meter node-meter-${orientation} node-meter-${size}`}>
      <div className="node-meter-fill" style={{ [orientation === 'horizontal' ? 'width' : 'height']: `${percent}%` }} />
      {peak > 0 && (
        <div
          className="node-meter-peak"
          style={{ [orientation === 'horizontal' ? 'left' : 'bottom']: `${peakPercent}%` }}
        />
      )}
    </div>
  );
}
