# Latent Resonator - Testing

Latent Resonator is a Bespoke Synth module (`bespoke-migration/module/`) backed by a Python bridge to ACE-Step (`bespoke-migration/ace-bridge/`). The retired Swift app is no longer built or tested.

## Bridge tests (no model, no GPU)

```
cd bespoke-migration/ace-bridge
pip install pytest numpy
pytest test_bridge.py -v
```

These cover the WAV helpers and the HTTP endpoints in passthrough mode. One live-inference test is skipped unless a real ACE-Step checkpoint is available and `ACE_BRIDGE_LIVE_INFER=1` is set. See `bespoke-migration/ace-bridge/README.md`.

## Running the bridge with neural inference

- Python 3.9-3.12 (ACE-Step's dependency stack does not yet support 3.13+).
- Run `bespoke-migration/ace-bridge/setup_ace_bridge.sh` to create a venv and, optionally, download the ACE-Step v1 3.5B checkpoint.
- Start the server: `python ace_bridge_server.py --model-path /path/to/model`.
- Without a model the server starts in passthrough mode, useful for testing the feedback loop without neural inference.

## Module build and manual checks

Build steps and the manual verification checklist for the Bespoke Synth module are in `bespoke-migration/module/BUILD_VERIFICATION.md`. Inference runs on a background thread on the local machine, so expect latency of seconds per pass, not audio-callback rates.
