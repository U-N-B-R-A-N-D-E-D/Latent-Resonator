#!/usr/bin/env bash
# ============================================================================
# ACE-Step Bridge Setup
# ============================================================================
#
# One-command setup for the standalone Python ACE-Step bridge server.
# Creates a virtual environment, installs dependencies, optionally downloads
# the ACE-Step model, and starts the bridge server.
#
# Supported model: ACE-Step v1 3.5B, the checkpoint the bridge is tested with.
# The ACE-Step pipeline itself downloads the checkpoint (about 7.7 GB) into the
# model directory the first time the server loads it.
#
# Usage:
#   ./setup_ace_bridge.sh                            # Setup + start (no model)
#   ./setup_ace_bridge.sh --with-model               # Setup + prepare the model directory + start
#   ./setup_ace_bridge.sh --start-only               # Skip setup, just start server
#   ./setup_ace_bridge.sh --help                     # Show help
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Self-contained: the venv, any cloned ACE-Step checkout, and downloaded
# models all live next to this script, so the bridge has no dependency on
# being checked out inside any particular project layout.
PROJECT_ROOT="$SCRIPT_DIR"
VENV_DIR="$PROJECT_ROOT/.venv-ace-bridge"
REQUIREMENTS="$SCRIPT_DIR/requirements_bridge.txt"
SERVER_SCRIPT="$SCRIPT_DIR/ace_bridge_server.py"
if [[ -d "$SCRIPT_DIR/../BespokeSynth.app" ]]; then
    MODELS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)/models"
else
    MODELS_ROOT="$PROJECT_ROOT/models"
fi
ACE_STEP_COMMIT="6ae0852b1388de6dc0cca26b31a86d711f723cb3"
DEFAULT_PORT=8976
DEFAULT_HOST="127.0.0.1"

# ---------------------------------------------------------------------------
# Model registry
# ---------------------------------------------------------------------------
# The bridge loads ACE-Step v1 3.5B. Other ACE-Step variants are not supported
# by the pipeline the bridge imports. The directory name matches the default
# the Bespoke module looks for: <folder containing the app>/models/ace-step.
# ---------------------------------------------------------------------------

DEFAULT_MODEL_TYPE="base"

resolve_model_registry() {
    case "$1" in
        base)
            HF_MODEL_ID="ACE-Step/ACE-Step-v1-3.5B"
            MODEL_DIR_SUFFIX="ace-step"
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
${CYAN}ACE-Step Bridge Setup${NC}

Usage:
  $(basename "$0") [OPTIONS]

Options:
  --with-model         Use the default model directory; the ACE-Step pipeline
                       downloads the v1 3.5B checkpoint (~7.7 GB) into it on
                       first load
  --model-path PATH    Use a custom model directory instead
  --start-only         Skip environment setup, just start the server
  --port PORT          Server port (default: $DEFAULT_PORT)
  --host HOST          Server bind host (default: $DEFAULT_HOST)
  --debug              Enable Flask debug mode
  --help               Show this help message

Examples:
  # First-time setup (no model — server runs in passthrough mode)
  $(basename "$0")

  # Full setup; the checkpoint (~7.7 GB) downloads on first server start
  $(basename "$0") --with-model

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
echo -e "${CYAN}║                ${GREEN}ACE-Step Bridge Server${CYAN}                ║${NC}"
echo -e "${CYAN}║            Neural Audio Inference Service            ║${NC}"
echo -e "${CYAN}║                                                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
log_info "Model: ${GREEN}${HF_MODEL_ID}${NC}"
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
            if ! git clone https://github.com/ace-step/ACE-Step.git "$ACE_STEP_REPO_DIR"; then
                log_error "Failed to clone ACE-Step repo"
                log_warn "Server will start in passthrough mode (no neural inference)"
            fi
        fi

        if [[ -d "$ACE_STEP_REPO_DIR/.git" ]]; then
            log_info "Pinning ACE-Step to the tested commit ${ACE_STEP_COMMIT:0:12}"
            (cd "$ACE_STEP_REPO_DIR" && git fetch --quiet origin && git checkout --quiet "$ACE_STEP_COMMIT")
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
        log_step "Preparing model directory"
        mkdir -p "$MODEL_DIR"
        MODEL_PATH="$MODEL_DIR"
        log_info "Model directory: $MODEL_DIR"
        log_info "The ACE-Step pipeline downloads ${HF_MODEL_ID} (~7.7 GB) into it"
        log_info "the first time the server loads the model. This can take a while."
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
    log_info "Callers will receive passthrough audio from /infer until a model is loaded."
    log_info "To load a model, restart with: --with-model or --model-path PATH"
    echo ""
fi

echo -e "${GREEN}Press Ctrl+C to stop the server${NC}"
echo ""

# Run the server (array expansion preserves quoting for paths with spaces)
exec python "$SERVER_SCRIPT" "${SERVER_ARGS[@]}"
