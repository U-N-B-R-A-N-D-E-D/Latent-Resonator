/**
    bespoke synth, a software modular synthesizer
    Copyright (C) 2021 Ryan Challinor (contact: awwbees@gmail.com)

    ModuleACEResonator: Copyright (C) 2026 UNBRANDED.
    Derived from Bespoke Synth's module template; licensed GPL-3.0-or-later.

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
#include <string>
#include <vector>

#include "Checkbox.h"
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

// Everything the worker needs for one chain of takes. Built on the UI thread
// (Poll), moved to the worker under a lock; never touched by the audio thread.
struct ACEInferJob
{
   std::vector<float> audio; // S(i) with N(mu,sigma) already applied for iteration 0
   int sampleRate{ 44100 };
   float guidance{ 7.0f };
   int steps{ 8 };
   int seed{ 0 }; // effective seed for iteration 0; iteration k uses seed + k
   float inputStrength{ 0.6f };
   float gamma{ 0.5f };
   float mu{ 0.0f };
   float sigma{ 0.0f };
   std::string prompt;
   float durationSeconds{ 4.0f };
   int iterations{ 1 };
   bool normalize{ true };
};

// Captures the live input signal into a rolling snapshot S(i), and on trigger sends
// S(i) + noise off to an ACE-Step bridge subprocess for neural regeneration, playing
// the result back in as the new output. With iterate > 1 the take is fed back as
// S(i+1) automatically. All network I/O and WAV decoding happens on worker threads
// so Process() and Poll() never block.
class ModuleACEResonator : public IAudioProcessor, public IDrawableModule, public IButtonListener, public IFloatSliderListener, public IIntSliderListener, public ITextEntryListener, public IPulseReceiver
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

   //IIntSliderListener
   void IntSliderUpdated(IntSlider* slider, int oldVal, double time) override {}

   //ITextEntryListener
   void TextEntryComplete(TextEntry* entry) override;

   void LoadLayout(const ofxJSONElement& moduleInfo) override;
   void SetUpFromSaveData() override;

   // Sliders, checkboxes and the prompt are saved by IDrawableModule itself;
   // connection fields are excluded so shipped patches stay portable.
   int GetModuleSaveStateRev() const override { return 1; }
   std::vector<IUIControl*> ControlsToIgnoreInSaveState() const override;

   // Called back from worker threads only. Each just updates an atomic (or a
   // small lock-guarded value never touched by Process()).
   void PublishOutputBuffer(std::vector<float>&& samples);
   void SetBridgeHealthy(bool healthy) { mBridgeHealthy.store(healthy, std::memory_order_release); }
   void SetInferInFlight(bool inFlight) { mInferInFlight.store(inFlight, std::memory_order_release); }
   void SetStatusMessage(const std::string& message);
   void SetBridgeInfo(const std::string& info, bool modelLoaded);
   void SetProgress(const std::string& phase, int step, int totalSteps, float elapsedSeconds, float etaSeconds);
   void ClearProgress();
   void SetIteration(int current, int total)
   {
      mIterationCurrent.store(current, std::memory_order_relaxed);
      mIterationTotal.store(total, std::memory_order_relaxed);
   }
   bool IsCancelRequested() const { return mCancelRequested.load(std::memory_order_acquire); }
   bool IsInferInFlight() const { return mInferInFlight.load(std::memory_order_acquire); }

private:
   void DrawModule() override;

   void TriggerRegenerate();
   void StartJobFromSnapshot();
   void LaunchBridgeProcess();
   void ShutdownBridge();
   std::string GetStatusMessage();

   bool mEnabled{ true };

   // A few seconds is enough to capture a meaningful musical snapshot without
   // letting a runaway trigger build an unbounded request (the bridge itself
   // caps request size at roughly 10 seconds of mono float32 audio).
   static constexpr float kMaxSnapshotSeconds = 6.0f;
   static constexpr int kDefaultBridgePort = 8976;
   static constexpr int kCrossfadeSamples = 512;

   RollingBuffer mInputSnapshot; // continuously written in Process(): this is S(i)
   std::vector<float> mPlaybackScratch; // audio-thread-only scratch, sized to gBufferSize
   std::vector<float> mTriggerScratch; // UI-thread-only, reused across triggers

   std::mt19937 mRandomEngine; // UI thread only
   std::normal_distribution<float> mNormalDist{ 0.0f, 1.0f };

   // UI controls
   FloatSlider* mInputStrengthSlider{ nullptr };
   IntSlider* mStepsSlider{ nullptr };
   FloatSlider* mGuidanceSlider{ nullptr };
   FloatSlider* mGammaSlider{ nullptr };
   FloatSlider* mMuSlider{ nullptr };
   FloatSlider* mSigmaSlider{ nullptr };
   TextEntry* mSeedEntry{ nullptr };
   Checkbox* mLockSeedCheckbox{ nullptr };
   FloatSlider* mDrySlider{ nullptr };
   FloatSlider* mOutGainSlider{ nullptr };
   Checkbox* mNormalizeCheckbox{ nullptr };
   Checkbox* mLoopCheckbox{ nullptr };
   IntSlider* mIterateSlider{ nullptr };
   ClickButton* mTriggerButton{ nullptr };
   ClickButton* mCancelButton{ nullptr };
   TextEntry* mPromptEntry{ nullptr };
   TextEntry* mModelPathEntry{ nullptr };
   TextEntry* mScriptPathEntry{ nullptr };
   TextEntry* mHostEntry{ nullptr };
   TextEntry* mPortEntry{ nullptr };

   float mInputStrength{ 0.6f }; // SDEdit-style: how much of the input survives
   int mSteps{ 8 };
   float mGuidance{ 7.0f };
   float mGamma{ 0.5f }; // bridge denoise_strength: scales the step count, not a mix amount
   float mMu{ 0.0f };
   float mSigma{ 0.0f };
   int mSeed{ -1 };
   bool mLockSeed{ false };
   int mLastSeed{ -1 }; // UI thread only
   float mDry{ 0.5f };
   float mOutGainDb{ 0.0f };
   bool mNormalize{ true };
   bool mLoop{ true };
   int mIterate{ 1 };
   char mPromptBuffer[MAX_TEXTENTRY_LENGTH]{};
   char mModelPathBuffer[MAX_TEXTENTRY_LENGTH]{};
   char mScriptPathBuffer[MAX_TEXTENTRY_LENGTH]{};
   char mHostBuffer[MAX_TEXTENTRY_LENGTH]{};
   int mPort{ kDefaultBridgePort };

   // Bridge subprocess lifecycle: only ever touched from the main/UI thread.
   juce::ChildProcess* mBridgeProcess{ nullptr };

   // Owns all blocking work (HTTP + WAV decode) on its own thread.
   std::unique_ptr<ACEBridgeWorker> mWorker;

   // Double-buffered output: the worker fills the back buffer, records its
   // length, then flips the read index, so Process() only ever sees a
   // fully-formed buffer with a matching length.
   std::vector<float> mOutputBuffers[2];
   int mOutputLengths[2]{ 0, 0 };
   std::atomic<int> mTakeState{ 0 }; // (serial << 1) | readIndex, one word so the audio thread can't see them torn; serial 0 = nothing published
   std::atomic<bool> mTriggerRequested{ false }; // set from any thread, consumed in Poll()
   std::atomic<bool> mCancelRequested{ false };

   // audio-thread-only playback state
   int mPlaybackPosition{ 0 };
   int mSeenTakeSerial{ 0 };
   int mFadeRemaining{ 0 };
   float mLastWetSample{ 0.0f };
   float mLastGain{ 1.0f };

   std::atomic<bool> mBridgeHealthy{ false };
   std::atomic<bool> mModelLoaded{ false };
   std::atomic<bool> mInferInFlight{ false };
   std::atomic<int> mIterationCurrent{ 0 };
   std::atomic<int> mIterationTotal{ 0 };

   float mControlsBottom{ 0 };

   ofMutex mStatusLock; // guards everything below between worker threads and DrawModule()
   std::string mStatusMessage{ "bridge starting..." };
   std::string mBridgeInfo{ "bridge: starting" };
   std::string mProgressPhase;
   int mProgressStep{ 0 };
   int mProgressTotal{ 0 };
   float mProgressElapsed{ 0 };
   float mProgressEta{ -1 };
};
