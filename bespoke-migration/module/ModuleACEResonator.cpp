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
//  ModuleACEResonator.cpp
//  modularSynth
//
//  Recursive neural audio resonator: S(i+1) = ACE(S(i) + N(mu,sigma), P, gamma)
//

#include "ModuleACEResonator.h"
#include "ModularSynth.h"
#include "Profiler.h"
#include "SynthGlobals.h"
#include "UIControlMacros.h"

#include <cstring>
#include <mutex>

#include "juce_audio_formats/juce_audio_formats.h"
#include "juce_core/juce_core.h"

namespace
{
   const char* kDefaultScriptPath = "ace-bridge/ace_bridge_server.py";
   const char* kDefaultHost = "127.0.0.1";

   // Bounded so a single stuck request can't wedge the worker thread forever;
   // inference itself is CPU-bound and can legitimately take many seconds.
   const int kHealthCheckTimeoutMs = 1500;
   const int kInferTimeoutMs = 180000;
   const int kShutdownTimeoutMs = 1500;

   void SetCString(char* dest, const std::string& value)
   {
      juce::String(value).copyToUTF8(dest, MAX_TEXTENTRY_LENGTH);
   }
}

// Owns every blocking operation the module needs (health polling, the /infer
// HTTP round-trip, WAV encode/decode) on a dedicated thread, so the audio
// thread and the UI thread never wait on the network or on the bridge's
// (potentially multi-second) inference time.
class ACEBridgeWorker : public juce::Thread
{
public:
   explicit ACEBridgeWorker(ModuleACEResonator& owner)
   : juce::Thread("ACEResonator Bridge Worker")
   , mOwner(owner)
   {
   }

   ~ACEBridgeWorker() override
   {
      signalThreadShouldExit();
      mWakeEvent.signal();
      stopThread(2000);
   }

   void SetConnection(const std::string& host, int port)
   {
      const std::lock_guard<ofMutex> lock(mConnectionLock);
      mHost = host;
      mPort = port;
   }

   // Called from the audio or UI thread (whichever trigger fired). Copies the
   // already-prepared request payload under a short lock and wakes the worker;
   // the caller's own copy of `audio` is left untouched.
   void RequestInfer(std::vector<float> audio, int sampleRate, float gamma, std::string prompt, float audioDurationSeconds)
   {
      {
         const std::lock_guard<ofMutex> lock(mRequestLock);
         mPendingAudio = std::move(audio);
         mPendingSampleRate = sampleRate;
         mPendingGamma = gamma;
         mPendingPrompt = std::move(prompt);
         mPendingDuration = audioDurationSeconds;
         mHasPendingInfer = true;
      }
      mWakeEvent.signal();
   }

   // Best-effort graceful shutdown, called directly (not via the run loop)
   // from the main thread during module teardown. Bounded by a short timeout
   // so module removal can never hang indefinitely on a stuck bridge process.
   void RequestShutdown()
   {
      std::string host;
      int port;
      GetConnection(host, port);

      juce::URL url("http://" + juce::String(host) + ":" + juce::String(port) + "/shutdown");
      url = url.withPOSTData(juce::String());

      auto stream = url.createInputStream(
      juce::URL::InputStreamOptions(juce::URL::ParameterHandling::inPostData)
      .withConnectionTimeoutMs(kShutdownTimeoutMs));

      if (stream != nullptr)
         stream->readEntireStreamAsString();
   }

   void run() override
   {
      while (!threadShouldExit())
      {
         mWakeEvent.wait(500);

         if (threadShouldExit())
            break;

         bool hasWork = false;
         std::vector<float> audio;
         int sampleRate = 44100;
         float gamma = 0.5f;
         std::string prompt;
         float duration = 4.0f;

         {
            const std::lock_guard<ofMutex> lock(mRequestLock);
            if (mHasPendingInfer)
            {
               hasWork = true;
               audio = std::move(mPendingAudio);
               sampleRate = mPendingSampleRate;
               gamma = mPendingGamma;
               prompt = std::move(mPendingPrompt);
               duration = mPendingDuration;
               mHasPendingInfer = false;
            }
         }

         if (hasWork)
            DoInfer(audio, sampleRate, gamma, prompt, duration);
         else
            DoHealthCheck();
      }
   }

private:
   void GetConnection(std::string& host, int& port)
   {
      const std::lock_guard<ofMutex> lock(mConnectionLock);
      host = mHost;
      port = mPort;
   }

   void DoHealthCheck()
   {
      std::string host;
      int port;
      GetConnection(host, port);

      int statusCode = 0;
      juce::URL url("http://" + juce::String(host) + ":" + juce::String(port) + "/health");
      auto stream = url.createInputStream(
      juce::URL::InputStreamOptions(juce::URL::ParameterHandling::inAddress)
      .withConnectionTimeoutMs(kHealthCheckTimeoutMs)
      .withStatusCode(&statusCode));

      if (stream == nullptr || statusCode != 200)
      {
         mOwner.SetBridgeHealthy(false);
         mOwner.SetModelLoaded(false);
         mOwner.SetStatusMessage("bridge unreachable at " + host + ":" + std::to_string(port));
         return;
      }

      juce::var parsed = juce::JSON::parse(stream->readEntireStreamAsString());
      bool modelLoaded = parsed.getProperty("model_loaded", false);
      juce::String modelType = parsed.getProperty("model_type", juce::var("none")).toString();

      mOwner.SetBridgeHealthy(true);
      mOwner.SetModelLoaded(modelLoaded);
      mOwner.SetStatusMessage(modelLoaded
                              ? ("connected - model loaded (" + modelType.toStdString() + ")")
                              : "connected - passthrough (no model loaded on bridge)");
   }

   void DoInfer(const std::vector<float>& audio, int sampleRate, float gamma, const std::string& prompt, float durationSeconds)
   {
      mOwner.SetStatusMessage("encoding snapshot and sending to bridge...");

      juce::MemoryBlock wavBlock;
      {
         juce::WavAudioFormat wavFormat;
         std::unique_ptr<juce::AudioFormatWriter> writer(wavFormat.createWriterFor(
         new juce::MemoryOutputStream(wavBlock, false), sampleRate, 1u, 32, {}, 0));

         if (writer == nullptr)
         {
            mOwner.SetStatusMessage("failed to encode snapshot as WAV");
            mOwner.SetInferInFlight(false);
            return;
         }

         const float* channels[] = { audio.data() };
         writer->writeFromFloatArrays(channels, 1, (int)audio.size());
      }

      juce::String audioBase64 = juce::Base64::toBase64(wavBlock.getData(), wavBlock.getSize());

      juce::DynamicObject::Ptr requestObj = new juce::DynamicObject();
      requestObj->setProperty("audio", audioBase64);
      requestObj->setProperty("prompt", juce::String(prompt));
      // gamma is the whitepaper's third resonator parameter; the bridge's closest
      // matching knob is denoise_strength (0 = passthrough, 1 = full effect).
      requestObj->setProperty("denoise_strength", (double)gamma);
      requestObj->setProperty("audio_duration", (double)durationSeconds);

      juce::String jsonBody = juce::JSON::toString(juce::var(requestObj.get()), true);

      std::string host;
      int port;
      GetConnection(host, port);

      juce::URL url("http://" + juce::String(host) + ":" + juce::String(port) + "/infer");
      url = url.withPOSTData(jsonBody);

      mOwner.SetStatusMessage("running ACE-Step inference (this can take a while)...");

      int statusCode = 0;
      auto stream = url.createInputStream(
      juce::URL::InputStreamOptions(juce::URL::ParameterHandling::inPostData)
      .withExtraHeaders("Content-Type: application/json")
      .withConnectionTimeoutMs(kInferTimeoutMs)
      .withStatusCode(&statusCode));

      if (stream == nullptr)
      {
         mOwner.SetBridgeHealthy(false);
         mOwner.SetStatusMessage("inference request failed: could not reach bridge");
         mOwner.SetInferInFlight(false);
         return;
      }

      juce::String responseText = stream->readEntireStreamAsString();
      juce::var response = juce::JSON::parse(responseText);

      if (statusCode != 200 || response.hasProperty("error"))
      {
         juce::String message = response.hasProperty("error")
                                ? response["error"].toString()
                                : ("HTTP " + juce::String(statusCode));
         mOwner.SetStatusMessage("inference error: " + message.toStdString());
         mOwner.SetInferInFlight(false);
         return;
      }

      juce::String outAudioBase64 = response["audio"].toString();

      juce::MemoryBlock outWavBytes;
      {
         juce::MemoryOutputStream mos(outWavBytes, false);
         if (!juce::Base64::convertFromBase64(mos, outAudioBase64))
         {
            mOwner.SetStatusMessage("bridge returned invalid base64 audio");
            mOwner.SetInferInFlight(false);
            return;
         }
      }

      juce::WavAudioFormat wavFormat;
      std::unique_ptr<juce::AudioFormatReader> reader(
      wavFormat.createReaderFor(new juce::MemoryInputStream(outWavBytes, false), true));

      if (reader == nullptr || reader->lengthInSamples <= 0)
      {
         mOwner.SetStatusMessage("could not decode WAV returned by bridge");
         mOwner.SetInferInFlight(false);
         return;
      }

      int numSamples = (int)reader->lengthInSamples;
      std::vector<float> decoded(numSamples);
      float* channelPtrs[] = { decoded.data() };
      reader->read(channelPtrs, 1, 0, numSamples);

      int outputSampleRate = (int)reader->sampleRate;
      mOwner.PublishOutputBuffer(std::move(decoded), outputSampleRate);
      mOwner.SetBridgeHealthy(true);
      mOwner.SetStatusMessage("regeneration complete (" + std::to_string(numSamples) + " samples @ " + std::to_string(outputSampleRate) + "Hz)");
      mOwner.SetInferInFlight(false);
   }

   ModuleACEResonator& mOwner;

   juce::WaitableEvent mWakeEvent;

   ofMutex mConnectionLock;
   std::string mHost{ "127.0.0.1" };
   int mPort{ 8976 };

   ofMutex mRequestLock;
   bool mHasPendingInfer{ false };
   std::vector<float> mPendingAudio;
   int mPendingSampleRate{ 44100 };
   float mPendingGamma{ 0.5f };
   std::string mPendingPrompt;
   float mPendingDuration{ 4.0f };
};

ModuleACEResonator::ModuleACEResonator()
: IAudioProcessor(gBufferSize)
, IDrawableModule(390, 140)
, mInputSnapshot(int(kMaxSnapshotSeconds * gSampleRate))
, mRandomEngine(std::random_device{}())
{
   SetCString(mScriptPathBuffer, kDefaultScriptPath);
   SetCString(mHostBuffer, kDefaultHost);

   mPlaybackScratch.resize(gBufferSize);
   mTriggerScratch.resize(mInputSnapshot.Size());
}

ModuleACEResonator::~ModuleACEResonator()
{
   ShutdownBridge();
}

void ModuleACEResonator::CreateUIControls()
{
   IDrawableModule::CreateUIControls();
   UIBLOCK0();
   TEXTENTRY(mPromptEntry, "prompt", 40, mPromptBuffer);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mMuSlider, "mu", &mMu, -1, 1);
   UIBLOCK_SHIFTRIGHT();
   FLOATSLIDER(mSigmaSlider, "sigma", &mSigma, 0, 1);
   UIBLOCK_SHIFTRIGHT();
   FLOATSLIDER(mGammaSlider, "gamma", &mGamma, 0, 1);
   UIBLOCK_NEWLINE();
   BUTTON(mTriggerButton, "regenerate");
   UIBLOCK_NEWLINE();
   TEXTENTRY(mScriptPathEntry, "bridge script", 34, mScriptPathBuffer);
   UIBLOCK_NEWLINE();
   TEXTENTRY(mHostEntry, "host", 16, mHostBuffer);
   UIBLOCK_SHIFTRIGHT();
   TEXTENTRY_NUM(mPortEntry, "port", 6, &mPort, 1, 65535);
   UIBLOCK_NEWLINE();
   ENDUIBLOCK(mWidth, mHeight);
}

void ModuleACEResonator::Init()
{
   IDrawableModule::Init();

   mWorker = std::make_unique<ACEBridgeWorker>(*this);
   mWorker->SetConnection(mHostBuffer, mPort);
   mWorker->startThread();

   LaunchBridgeProcess();
}

void ModuleACEResonator::Exit()
{
   ShutdownBridge();

   IDrawableModule::Exit();
}

void ModuleACEResonator::LaunchBridgeProcess()
{
   if (mBridgeProcess != nullptr)
   {
      mBridgeProcess->kill();
      delete mBridgeProcess;
      mBridgeProcess = nullptr;
   }

   juce::StringArray args;
   args.add("python3");
   args.add(juce::String(mScriptPathBuffer));
   args.add("--host");
   args.add(juce::String(mHostBuffer));
   args.add("--port");
   args.add(juce::String(mPort));

   mBridgeProcess = new juce::ChildProcess();
   bool success = mBridgeProcess->start(args);
   if (!success)
   {
      ofLog() << "ModuleACEResonator: failed to launch ACE bridge process";
      delete mBridgeProcess;
      mBridgeProcess = nullptr;
   }
}

void ModuleACEResonator::ShutdownBridge()
{
   if (mWorker != nullptr)
   {
      mWorker->RequestShutdown();
      mWorker.reset();
   }

   if (mBridgeProcess != nullptr)
   {
      if (mBridgeProcess->isRunning())
         mBridgeProcess->kill();
      delete mBridgeProcess;
      mBridgeProcess = nullptr;
   }
}

void ModuleACEResonator::Poll()
{
   IDrawableModule::Poll();

   if (mBridgeProcess != nullptr && !mBridgeProcess->isRunning())
   {
      SetStatusMessage("bridge process exited unexpectedly");
      delete mBridgeProcess;
      mBridgeProcess = nullptr;
   }
}

void ModuleACEResonator::Process(double time)
{
   PROFILER(ModuleACEResonator);

   IAudioReceiver* target = GetTarget();

   ComputeSliders(0);
   SyncBuffers(1);

   int bufferSize = GetBuffer()->BufferSize();
   assert(bufferSize == gBufferSize);

   // Continuously record S(i): whatever is coming in now becomes the seed for
   // the next regeneration cycle, whenever the next trigger arrives.
   mInputSnapshot.WriteChunk(GetBuffer()->GetChannel(0), bufferSize, 0);

   if (mEnabled && target != nullptr)
   {
      int outputLength = mOutputLength.load(std::memory_order_acquire);

      if (outputLength > 0)
      {
         if (mPlaybackPosition >= outputLength)
            mPlaybackPosition %= outputLength;

         int readIndex = mOutputReadIndex.load(std::memory_order_acquire);
         const std::vector<float>& playback = mOutputBuffers[readIndex];

         for (int i = 0; i < bufferSize; ++i)
         {
            mPlaybackScratch[i] = playback[mPlaybackPosition];
            mPlaybackPosition = (mPlaybackPosition + 1) % outputLength;
         }
      }
      else
      {
         // Nothing generated yet: hold silence rather than block or glitch.
         std::fill(mPlaybackScratch.begin(), mPlaybackScratch.begin() + bufferSize, 0.0f);
      }

      ChannelBuffer* out = target->GetBuffer();
      for (int ch = 0; ch < out->NumActiveChannels(); ++ch)
         Add(out->GetChannel(ch), mPlaybackScratch.data(), bufferSize);

      GetVizBuffer()->WriteChunk(mPlaybackScratch.data(), bufferSize, 0);
   }

   GetBuffer()->Reset();
}

void ModuleACEResonator::OnPulse(double time, float velocity, int flags)
{
   TriggerRegenerate();
}

void ModuleACEResonator::ButtonClicked(ClickButton* button, double time)
{
   if (button == mTriggerButton)
      TriggerRegenerate();
}

void ModuleACEResonator::TextEntryComplete(TextEntry* entry)
{
   if ((entry == mHostEntry || entry == mPortEntry) && mWorker != nullptr)
      mWorker->SetConnection(mHostBuffer, mPort);
}

void ModuleACEResonator::TriggerRegenerate()
{
   if (mWorker == nullptr)
      return;

   if (!mBridgeHealthy.load(std::memory_order_acquire))
   {
      SetStatusMessage("can't regenerate: bridge is not reachable");
      return;
   }

   if (mInferInFlight.exchange(true, std::memory_order_acq_rel))
      return; // an inference is already running; drop this trigger rather than queue it up

   int snapshotLength = mInputSnapshot.Size();
   mInputSnapshot.ReadChunk(mTriggerScratch.data(), snapshotLength, 0, 0);

   // Inject N(mu,sigma) before sending, per the resonator's recursive formula
   // S(i+1) = ACE(S(i) + N(mu,sigma), P, gamma) - the noise has to land in the
   // audio itself, since the bridge has no separate noise-parameter inputs.
   for (int i = 0; i < snapshotLength; ++i)
      mTriggerScratch[i] += mMu + mSigma * mNormalDist(mRandomEngine);

   float durationSeconds = float(snapshotLength) / gSampleRate;
   mWorker->RequestInfer(mTriggerScratch, gSampleRate, mGamma, std::string(mPromptBuffer), durationSeconds);
}

void ModuleACEResonator::PublishOutputBuffer(std::vector<float>&& samples, int sampleRate)
{
   int backIndex = 1 - mOutputReadIndex.load(std::memory_order_relaxed);
   mOutputBuffers[backIndex] = std::move(samples);
   mOutputLength.store((int)mOutputBuffers[backIndex].size(), std::memory_order_release);
   mOutputReadIndex.store(backIndex, std::memory_order_release);
   (void)sampleRate; // no resampling to the engine's rate yet; see known gaps
}

void ModuleACEResonator::SetStatusMessage(const std::string& message)
{
   const std::lock_guard<ofMutex> lock(mStatusLock);
   mStatusMessage = message;
}

std::string ModuleACEResonator::GetStatusMessage()
{
   const std::lock_guard<ofMutex> lock(mStatusLock);
   return mStatusMessage;
}

void ModuleACEResonator::DrawModule()
{
   if (Minimized() || IsVisible() == false)
      return;

   mPromptEntry->Draw();
   mMuSlider->Draw();
   mSigmaSlider->Draw();
   mGammaSlider->Draw();
   mTriggerButton->Draw();
   mScriptPathEntry->Draw();
   mHostEntry->Draw();
   mPortEntry->Draw();

   ofPushStyle();
   ofSetColor(255, 255, 255);
   std::string status = GetStatusMessage();
   if (mInferInFlight.load())
      status = "[generating] " + status;
   DrawTextNormal(status, 5, mHeight - 8, 10);
   ofPopStyle();
}

void ModuleACEResonator::LoadLayout(const ofxJSONElement& moduleInfo)
{
   mModuleSaveData.LoadString("target", moduleInfo);

   SetUpFromSaveData();
}

void ModuleACEResonator::SetUpFromSaveData()
{
   SetTarget(TheSynth->FindModule(mModuleSaveData.GetString("target")));
}
