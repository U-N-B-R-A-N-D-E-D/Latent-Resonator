#!/usr/bin/env bash
# ============================================================================
# Latent Resonator — ACE-Step Bridge Setup
# ============================================================================
#
# One-command setup for the Python ACE-Step bridge server.
# Creates a virtual environment, installs dependencies, optionally downloads
# the ACE-Step model, and starts the bridge server.
#
# Model types (ACE-Step 1.5):
#   base  — CFG + lego/extract/complete tasks (DEFAULT, per whitepaper §4.2)
#   sft   — CFG supported, 50 steps, high quality
#   turbo — 8 steps, NO CFG, fast (NOT recommended for Latent Resonator)
#
# Usage:
#   ./setup_ace_bridge.sh                            # Setup + start (no model)
#   ./setup_ace_bridge.sh --with-model               # Setup + download Base model + start
#   ./setup_ace_bridge.sh --with-model --model-type sft   # Download SFT variant
#   ./setup_ace_bridge.sh --start-only               # Skip setup, just start server
#   ./setup_ace_bridge.sh --help                     # Show help
#
# White paper reference:
#   §6.1 The model as "Black Box Resonator"
#   §3.3 Recursive formula: S_{i+1} = ACE(S_i + N(μ,σ), P, γ)
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VENV_DIR="$PROJECT_ROOT/.venv-ace-bridge"
REQUIREMENTS="$SCRIPT_DIR/requirements_bridge.txt"
SERVER_SCRIPT="$SCRIPT_DIR/ace_bridge_server.py"
MODELS_ROOT="$PROJECT_ROOT/models"
DEFAULT_PORT=8976
DEFAULT_HOST="127.0.0.1"

# ---------------------------------------------------------------------------
# ACE-Step 1.5 Model Registry
# ---------------------------------------------------------------------------
# Maps --model-type to HuggingFace repo ID and local directory name.
# Default is "base" — required for CFG overdriving (whitepaper §4.2).
#
# If HuggingFace repo names change, update only these arrays.
# ---------------------------------------------------------------------------

DEFAULT_MODEL_TYPE="base"

# Resolve HuggingFace repo ID and local dir suffix from model type.
# Compatible with macOS bash 3.2 (no associative arrays).
resolve_model_registry() {
    case "$1" in
        base)
            HF_MODEL_ID="ACE-Step/Ace-Step1.5"
            MODEL_DIR_SUFFIX="ace-step-v1.5-base"
            ;;
        sft)
            HF_MODEL_ID="ACE-Step/acestep-v15-sft"
            MODEL_DIR_SUFFIX="ace-step-v1.5-sft"
            ;;
        turbo)
            HF_MODEL_ID="ACE-Step/acestep-v15-turbo-continuous"
            MODEL_DIR_SUFFIX="ace-step-v1.5-turbo"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

show_help() {
    cat <<EOF
${CYAN}Latent Resonator — ACE-Step Bridge Setup${NC}

Usage:
  $(basename "$0") [OPTIONS]

Options:
  --with-model         Download ACE-Step 1.5 model from HuggingFace
  --model-type TYPE    Model variant: base (default), sft, turbo
                         base  — CFG + lego/extract/complete (whitepaper default)
                         sft   — CFG supported, high quality
                         turbo — NO CFG, fast (not recommended)
  --model-path PATH    Use a custom model path instead of downloading
  --start-only         Skip environment setup, just start the server
  --port PORT          Server port (default: $DEFAULT_PORT)
  --host HOST          Server bind host (default: $DEFAULT_HOST)
  --debug              Enable Flask debug mode
  --help               Show this help message

Examples:
  # First-time setup (no model — server runs in passthrough mode)
  $(basename "$0")

  # Full setup with Base model download (~7GB, recommended)
  $(basename "$0") --with-model

  # Download the SFT variant instead
  $(basename "$0") --with-model --model-type sft

  # Start server with existing model at custom path
  $(basename "$0") --start-only --model-path /path/to/model

  # Custom port
  $(basename "$0") --port 9000

EOF
}

# ---------------------------------------------------------------------------
# Parse Arguments
# ---------------------------------------------------------------------------

WITH_MODEL=false
MODEL_PATH=""
MODEL_TYPE="$DEFAULT_MODEL_TYPE"
START_ONLY=false
PORT=$DEFAULT_PORT
HOST=$DEFAULT_HOST
DEBUG_FLAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --with-model)
            WITH_MODEL=true
            shift ;;
        --model-type)
            MODEL_TYPE="$2"
            # Validate model type
            if ! resolve_model_registry "$MODEL_TYPE"; then
                log_error "Unknown model type: $MODEL_TYPE"
                log_info "Valid types: base, sft, turbo"
                exit 1
            fi
            shift 2 ;;
        --model-path)
            MODEL_PATH="$2"
            shift 2 ;;
        --start-only)
            START_ONLY=true
            shift ;;
        --port)
            PORT="$2"
            shift 2 ;;
        --host)
            HOST="$2"
            shift 2 ;;
        --debug)
            DEBUG_FLAG="--debug"
            shift ;;
        --help|-h)
            show_help
            exit 0 ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1 ;;
    esac
done

# Resolve model registry values for the selected type
resolve_model_registry "$MODEL_TYPE"
MODEL_DIR="$MODELS_ROOT/$MODEL_DIR_SUFFIX"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                      ║${NC}"
echo -e "${CYAN}║   ${GREEN}Latent Resonator${CYAN} — ACE-Step Bridge Server          ║${NC}"
echo -e "${CYAN}║   Non-Linear Spectral Processor via Neural Inference ║${NC}"
echo -e "${CYAN}║                                                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
log_info "Model type: ${GREEN}${MODEL_TYPE}${NC} (${HF_MODEL_ID})"
if [[ "$MODEL_TYPE" == "turbo" ]]; then
    log_warn "Turbo model does NOT support CFG — whitepaper §4.2 overdriving will be inactive."
fi
echo ""

# ---------------------------------------------------------------------------
# Pre-flight Checks
# ---------------------------------------------------------------------------

log_step "Pre-flight Checks"

# Check Python — prefer 3.12/3.11 explicitly (ACE-Step deps need Python <3.13)
PYTHON=""
for candidate in python3.12 python3.11 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /usr/local/bin/python3 python3; do
    if command -v "$candidate" &>/dev/null; then
        _PV_MAJOR=$($candidate -c 'import sys; print(sys.version_info.major)' 2>/dev/null)
        _PV_MINOR=$($candidate -c 'import sys; print(sys.version_info.minor)' 2>/dev/null)
        if [[ "$_PV_MAJOR" == "3" ]] && [[ "$_PV_MINOR" -ge 9 ]] && [[ "$_PV_MINOR" -lt 13 ]]; then
            PYTHON="$candidate"
            break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    # Last resort: accept any python3 even if >= 3.13 (some deps may fail)
    if command -v python3 &>/dev/null; then
        PYTHON="python3"
        log_warn "Only found $(python3 --version 2>&1). ACE-Step prefers Python 3.9–3.12."
    else
        log_error "Python 3 not found. Please install Python 3.9–3.12 first."
        echo "  macOS: brew install python@3.12"
        echo "  Or: https://www.python.org/downloads/"
        exit 1
    fi
fi

PYTHON_VERSION=$($PYTHON --version 2>&1)
log_ok "Found $PYTHON_VERSION ($(which $PYTHON))"

# Check Python version >= 3.9
PYTHON_MAJOR=$($PYTHON -c 'import sys; print(sys.version_info.major)')
PYTHON_MINOR=$($PYTHON -c 'import sys; print(sys.version_info.minor)')
if [[ $PYTHON_MAJOR -lt 3 ]] || [[ $PYTHON_MAJOR -eq 3 && $PYTHON_MINOR -lt 9 ]]; then
    log_error "Python 3.9+ required, found $PYTHON_MAJOR.$PYTHON_MINOR"
    exit 1
fi

# Check server script exists
if [[ ! -f "$SERVER_SCRIPT" ]]; then
    log_error "Bridge server script not found: $SERVER_SCRIPT"
    exit 1
fi

# ---------------------------------------------------------------------------
# Virtual Environment Setup
# ---------------------------------------------------------------------------

if [[ "$START_ONLY" == false ]]; then
    log_step "Python Virtual Environment"

    if [[ -d "$VENV_DIR" ]]; then
        log_info "Virtual environment already exists at $VENV_DIR"
        log_info "Activating..."
    else
        log_info "Creating virtual environment at $VENV_DIR"
        $PYTHON -m venv "$VENV_DIR"
        log_ok "Virtual environment created"
    fi

    # Activate venv
    source "$VENV_DIR/bin/activate"
    log_ok "Activated: $(which python)"

    # Upgrade pip
    log_info "Upgrading pip..."
    pip install --upgrade pip --quiet

    # -----------------------------------------------------------------------
    # Install Dependencies
    # -----------------------------------------------------------------------

    log_step "Installing Dependencies"

    if [[ -f "$REQUIREMENTS" ]]; then
        log_info "Installing from $REQUIREMENTS"
        pip install -r "$REQUIREMENTS" --quiet
        log_ok "Dependencies installed"
    else
        # Fallback: install core dependencies inline
        log_warn "requirements_bridge.txt not found, installing core dependencies..."
        pip install flask numpy --quiet

        # Optional: install torch for GPU acceleration
        log_info "Installing PyTorch (for model inference)..."
        pip install torch --quiet 2>/dev/null || \
            log_warn "PyTorch installation failed — server will run in passthrough mode"

        # Optional: install soundfile for robust WAV handling
        pip install soundfile --quiet 2>/dev/null || \
            log_warn "soundfile not installed — using fallback WAV codec"

        log_ok "Core dependencies installed"
    fi

    # -----------------------------------------------------------------------
    # ACE-Step Package (from GitHub — not on PyPI)
    # -----------------------------------------------------------------------
    # The ace_step Python package provides ACEStepPipeline, which is required
    # for neural inference. It must be installed from the GitHub repo.
    # This step is always run when --with-model is requested.

    ACE_STEP_REPO_DIR="$PROJECT_ROOT/ACE-Step"

    if [[ "$WITH_MODEL" == true ]]; then
        log_step "Installing ACE-Step Package"

        if [[ -d "$ACE_STEP_REPO_DIR" ]] && [[ -f "$ACE_STEP_REPO_DIR/setup.py" || -f "$ACE_STEP_REPO_DIR/pyproject.toml" ]]; then
            log_info "ACE-Step repo already cloned: $ACE_STEP_REPO_DIR"
        else
            log_info "Cloning ACE-Step from GitHub..."
            git clone https://github.com/ace-step/ACE-Step.git "$ACE_STEP_REPO_DIR" 2>&1 | tail -3
            if [[ $? -ne 0 ]]; then
                log_error "Failed to clone ACE-Step repo"
                log_warn "Server will start in passthrough mode (no neural inference)"
            fi
        fi

        if [[ -d "$ACE_STEP_REPO_DIR" ]]; then
            # Install ACE-Step without its full dependency tree to avoid
            # pinned versions that may not be available (e.g. spacy==3.8.4).
            log_info "Installing ACE-Step package (--no-deps)..."
            pip install -e "$ACE_STEP_REPO_DIR" --no-deps --quiet 2>&1 | tail -5

            # Install the actual inference dependencies explicitly.
            # These are the packages required by acestep.pipeline_ace_step
            # at import time and during inference.
            log_info "Installing inference dependencies..."
            pip install torch torchaudio torchvision transformers==4.50.0 \
                        diffusers accelerate==1.6.0 soundfile==0.13.1 \
                        numpy tqdm loguru spacy py3langid pypinyin \
                        num2words hangul-romanize librosa matplotlib \
                        pytorch_lightning peft cutlet "fugashi[unidic-lite]" \
                        click --quiet 2>&1 | tail -5
            if [[ $? -eq 0 ]]; then
                log_ok "ACE-Step package + inference deps installed"
            else
                log_warn "Some inference deps failed — server may run in passthrough mode"
            fi
        fi
    fi

    # -----------------------------------------------------------------------
    # Model Download (optional)
    # -----------------------------------------------------------------------

    if [[ "$WITH_MODEL" == true ]] && [[ -z "$MODEL_PATH" ]]; then
        log_step "Downloading ACE-Step Model (${MODEL_TYPE})"

        # Check if model already downloaded
        if [[ -d "$MODEL_DIR" ]] && [[ "$(ls -A "$MODEL_DIR" 2>/dev/null)" ]]; then
            log_info "Model directory already exists: $MODEL_DIR"
            log_info "Skipping download (delete directory to re-download)"
            MODEL_PATH="$MODEL_DIR"
        else
            log_info "Model type: $MODEL_TYPE"
            log_info "HuggingFace repo: $HF_MODEL_ID"
            log_info "Local directory: $MODEL_DIR"
            log_info "Downloading (~7GB)... this may take a while."

            # Ensure models root exists
            mkdir -p "$MODELS_ROOT"

            # Install huggingface_hub if not present
            pip install huggingface_hub --quiet

            # Download using huggingface-cli
            python -c "
from huggingface_hub import snapshot_download
print('Downloading $HF_MODEL_ID to $MODEL_DIR')
snapshot_download(
    repo_id='$HF_MODEL_ID',
    local_dir='$MODEL_DIR',
    local_dir_use_symlinks=False,
)
print('Download complete!')
"
            if [[ $? -eq 0 ]]; then
                MODEL_PATH="$MODEL_DIR"
                log_ok "Model ($MODEL_TYPE) downloaded to $MODEL_DIR"
            else
                log_error "Model download failed"
                log_warn "Server will start in passthrough mode"
            fi
        fi
    fi
else
    # Start-only mode — activate existing venv
    if [[ -d "$VENV_DIR" ]]; then
        source "$VENV_DIR/bin/activate"
        log_ok "Activated existing venv: $(which python)"
    else
        log_warn "No virtual environment found. Using system Python."
        log_warn "Run without --start-only first to set up the environment."
    fi
fi

# ---------------------------------------------------------------------------
# Start Server
# ---------------------------------------------------------------------------

log_step "Starting ACE-Step Bridge Server"

# Build argument array to avoid shell injection via unquoted expansion.
# MODEL_PATH and other user-supplied values are safely quoted as array elements.
SERVER_ARGS=("--host" "$HOST" "--port" "$PORT")

if [[ -n "$MODEL_PATH" ]]; then
    SERVER_ARGS+=("--model-path" "$MODEL_PATH")
    log_info "Model path: $MODEL_PATH"
fi

if [[ -n "$DEBUG_FLAG" ]]; then
    SERVER_ARGS+=("--debug")
fi

log_info "Server: http://$HOST:$PORT"
log_info "Health: http://$HOST:$PORT/health"
log_info "Infer:  http://$HOST:$PORT/infer"
echo ""

if [[ -z "$MODEL_PATH" ]]; then
    log_warn "No model loaded — running in passthrough mode"
    log_info "The Swift app will use its DSP SpectralProcessor as fallback."
    log_info "To load a model, restart with: --with-model or --model-path PATH"
    echo ""
fi

echo -e "${GREEN}Press Ctrl+C to stop the server${NC}"
echo ""

# Run the server (array expansion preserves quoting for paths with spaces)
exec python "$SERVER_SCRIPT" "${SERVER_ARGS[@]}"
