/**
    bespoke synth, a software modular synthesizer
    Copyright (C) 2021 Ryan Challinor (contact: awwbees@gmail.com)

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
**/
//
//  ModuleACEResonator.h
//  modularSynth
//
//  Recursive neural audio resonator: S(i+1) = ACE(S(i) + N(mu,sigma), P, gamma)
//

#pragma once

#include <atomic>
#include <memory>
#include <random>
#include <vector>

#include "ClickButton.h"
#include "IAudioProcessor.h"
#include "IDrawableModule.h"
#include "IPulseReceiver.h"
#include "RollingBuffer.h"
#include "Slider.h"
#include "TextEntry.h"

namespace juce
{
   class ChildProcess;
}

class ACEBridgeWorker;

// Captures the live input signal into a rolling snapshot S(i), and on trigger sends
// S(i) + noise off to an ACE-Step bridge subprocess for neural regeneration, playing
// the result back in as the new output - which then becomes S(i+1)'s seed once the
// next trigger arrives. All network I/O and WAV decoding happens on a dedicated
// worker thread so Process() and Poll() never block.
class ModuleACEResonator : public IAudioProcessor, public IDrawableModule, public IButtonListener, public IFloatSliderListener, public ITextEntryListener, public IPulseReceiver
{
public:
   ModuleACEResonator();
   ~ModuleACEResonator();

   static IDrawableModule* Create() { return new ModuleACEResonator(); }
   static bool AcceptsAudio() { return true; }
   static bool AcceptsNotes() { return false; }
   static bool AcceptsPulses() { return true; }

   void CreateUIControls() override;
   void Init() override;
   void Exit() override;
   void Poll() override;

   //IAudioSource / IAudioReceiver
   void Process(double time) override;
   void SetEnabled(bool enabled) override { mEnabled = enabled; }
   bool IsEnabled() const override { return mEnabled; }
   InputMode GetInputMode() override { return kInputMode_Mono; }

   //IPulseReceiver
   void OnPulse(double time, float velocity, int flags) override;

   //IButtonListener
   void ButtonClicked(ClickButton* button, double time) override;

   //IFloatSliderListener
   void FloatSliderUpdated(FloatSlider* slider, float oldVal, double time) override {}

   //ITextEntryListener
   void TextEntryComplete(TextEntry* entry) override;

   void LoadLayout(const ofxJSONElement& moduleInfo) override;
   void SetUpFromSaveData() override;

   // Called back from the worker thread only. Each of these just updates an
   // atomic (or a small lock-guarded status string never touched by Process()),
   // so it is safe to call from a non-audio thread.
   void PublishOutputBuffer(std::vector<float>&& samples, int sampleRate);
   void SetBridgeHealthy(bool healthy) { mBridgeHealthy.store(healthy, std::memory_order_release); }
   void SetModelLoaded(bool loaded) { mModelLoaded.store(loaded, std::memory_order_release); }
   void SetInferInFlight(bool inFlight) { mInferInFlight.store(inFlight, std::memory_order_release); }
   void SetStatusMessage(const std::string& message);

private:
   void DrawModule() override;

   void TriggerRegenerate();
   void LaunchBridgeProcess();
   void ShutdownBridge();
   std::string GetStatusMessage();

   bool mEnabled{ true };

   // A few seconds is enough to capture a meaningful musical snapshot without
   // letting a runaway trigger build an unbounded request (the bridge itself
   // caps request size at roughly 10 seconds of mono float32 audio).
   static constexpr float kMaxSnapshotSeconds = 6.0f;
   static constexpr int kDefaultBridgePort = 8976;

   RollingBuffer mInputSnapshot; // continuously written in Process(): this is S(i)
   std::vector<float> mPlaybackScratch; // audio-thread-only scratch, sized to gBufferSize
   std::vector<float> mTriggerScratch; // reused across triggers to avoid per-trigger allocation

   std::mt19937 mRandomEngine;
   std::normal_distribution<float> mNormalDist{ 0.0f, 1.0f };

   // UI controls
   FloatSlider* mMuSlider{ nullptr };
   FloatSlider* mSigmaSlider{ nullptr };
   FloatSlider* mGammaSlider{ nullptr };
   ClickButton* mTriggerButton{ nullptr };
   TextEntry* mPromptEntry{ nullptr };
   TextEntry* mScriptPathEntry{ nullptr };
   TextEntry* mHostEntry{ nullptr };
   TextEntry* mPortEntry{ nullptr };

   float mMu{ 0.0f };
   float mSigma{ 0.0f };
   float mGamma{ 0.5f };
   char mPromptBuffer[MAX_TEXTENTRY_LENGTH]{};
   char mScriptPathBuffer[MAX_TEXTENTRY_LENGTH]{};
   char mHostBuffer[MAX_TEXTENTRY_LENGTH]{};
   int mPort{ kDefaultBridgePort };

   // Bridge subprocess lifecycle: only ever touched from the main/UI thread
   // (Init(), Poll(), Exit(), the destructor), mirroring SamplePlayer's
   // mRunningProcess pattern.
   juce::ChildProcess* mBridgeProcess{ nullptr };

   // Owns all blocking work (HTTP + WAV decode) on its own thread.
   std::unique_ptr<ACEBridgeWorker> mWorker;

   // Double-buffered output: the worker writes into the "back" buffer and then
   // atomically publishes it, so Process() (audio thread) only ever reads a
   // fully-formed buffer and never touches the one the worker might still be
   // filling in.
   std::vector<float> mOutputBuffers[2];
   std::atomic<int> mOutputReadIndex{ 0 };
   std::atomic<int> mOutputLength{ 0 };
   int mPlaybackPosition{ 0 }; // audio-thread-only

   std::atomic<bool> mBridgeHealthy{ false };
   std::atomic<bool> mModelLoaded{ false };
   std::atomic<bool> mInferInFlight{ false };

   ofMutex mStatusLock; // guards mStatusMessage between the worker thread and Poll()/DrawModule()
   std::string mStatusMessage{ "bridge starting..." };
};
