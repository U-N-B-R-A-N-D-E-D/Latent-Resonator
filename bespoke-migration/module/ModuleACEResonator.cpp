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

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>

#include "juce_audio_formats/juce_audio_formats.h"
#include "juce_core/juce_core.h"

namespace
{
   const char* kDefaultScriptPath = "ace-bridge/ace_bridge_server.py";
   const char* kDefaultHost = "127.0.0.1";
   const char* kModelPathEnvVar = "LATENT_RESONATOR_MODEL_PATH";

   // Bounded so a single stuck request can't wedge the worker thread forever.
   const int kHealthCheckTimeoutMs = 1500;
   const int kProgressTimeoutMs = 600;
   const int kInferTimeoutMs = 180000;
   const int kShutdownTimeoutMs = 1500;
   const int kProgressPollMs = 250;

   // -3 dBFS; float16 output is quiet and unpredictable in level.
   const float kNormalizeTargetPeak = 0.70795f;

   void SetCString(char* dest, const std::string& value)
   {
      juce::String(value).copyToUTF8(dest, MAX_TEXTENTRY_LENGTH);
   }

   // A GUI app launched via Finder/`open` gets the minimal PATH launchd
   // provides (no Homebrew, no pyenv) -- a bare "python3" that resolves fine
   // from a Terminal shell silently fails to launch here. Resolve an
   // absolute path instead: prefer a venv sitting next to the bridge script,
   // then fall back to common absolute install locations.
   juce::String ResolveBridgePythonExecutable(const juce::String& scriptPath)
   {
      juce::File script(scriptPath);
      juce::File venvPython = script.getParentDirectory().getChildFile(".venv-ace-bridge/bin/python3");
      if (venvPython.existsAsFile())
         return venvPython.getFullPathName();

      static const char* kCandidates[] = {
         "/opt/homebrew/bin/python3.12",
         "/opt/homebrew/bin/python3.11",
         "/usr/local/bin/python3",
         "/usr/bin/python3",
         "/opt/homebrew/bin/python3",
      };
      for (auto* candidate : kCandidates)
      {
         if (juce::File(candidate).existsAsFile())
            return juce::String(candidate);
      }

      return "python3"; // last resort -- may still work if PATH happens to be set up
   }

   // The directory that contains the running .app bundle.
   juce::File GetAppContainerDirectory()
   {
      juce::File exe = juce::File::getSpecialLocation(juce::File::currentExecutableFile);
      // exe = .../BespokeSynth.app/Contents/MacOS/BespokeSynth
      juce::File appBundle = exe.getParentDirectory().getParentDirectory().getParentDirectory();
      return appBundle.getParentDirectory();
   }

   // A relative default only resolves against whatever working directory the
   // OS launched this process with -- unpredictable for a Finder-launched .app.
   // Look for ace-bridge/ next to the .app first.
   juce::String ResolveDefaultScriptPath()
   {
      juce::File sibling = GetAppContainerDirectory().getChildFile("ace-bridge/ace_bridge_server.py");
      if (sibling.existsAsFile())
         return sibling.getFullPathName();

      return kDefaultScriptPath;
   }

   // Env var wins so a patch shipped to another machine needs no edits; then
   // models/ace-step in the folder that contains the .app (the layout the
   // release zip and setup_ace_bridge.sh use); empty means passthrough.
   juce::String ResolveDefaultModelPath()
   {
      juce::String fromEnv = juce::SystemStats::getEnvironmentVariable(kModelPathEnvVar, juce::String());
      if (fromEnv.isNotEmpty())
         return fromEnv;

      juce::File sibling = GetAppContainerDirectory().getChildFile("models/ace-step");
      if (sibling.isDirectory())
         return sibling.getFullPathName();

      return juce::String();
   }

   std::vector<float> ResampleLinear(const std::vector<float>& in, int srcRate, int dstRate)
   {
      if (srcRate == dstRate || srcRate <= 0 || dstRate <= 0 || in.size() < 2)
         return in;
      size_t outSize = (size_t)((double)in.size() * dstRate / srcRate);
      std::vector<float> out(outSize);
      double ratio = (double)srcRate / dstRate;
      for (size_t i = 0; i < outSize; ++i)
      {
         double pos = i * ratio;
         size_t i0 = std::min((size_t)pos, in.size() - 1);
         size_t i1 = std::min(i0 + 1, in.size() - 1);
         float frac = (float)(pos - (double)i0);
         out[i] = in[i0] + (in[i1] - in[i0]) * frac;
      }
      return out;
   }

   std::string Truncate(const std::string& s, size_t maxChars)
   {
      if (s.size() <= maxChars)
         return s;
      return s.substr(0, maxChars - 3) + "...";
   }

   std::string FormatFloat(float v, int digits)
   {
      char buf[32];
      std::snprintf(buf, sizeof(buf), "%.*f", digits, v);
      return buf;
   }
}

// Polls GET /progress while a request is in flight. The infer round-trip blocks
// its own thread for the whole take, so progress needs a thread of its own.
class ACEProgressPoller : public juce::Thread
{
public:
   explicit ACEProgressPoller(ModuleACEResonator& owner)
   : juce::Thread("ACEResonator Progress Poller")
   , mOwner(owner)
   {
   }

   ~ACEProgressPoller() override
   {
      signalThreadShouldExit();
      mWake.signal();
      stopThread(2000);
   }

   void SetConnection(const std::string& host, int port)
   {
      const std::lock_guard<ofMutex> lock(mLock);
      mHost = host;
      mPort = port;
   }

   void run() override
   {
      while (!threadShouldExit())
      {
         mWake.wait(kProgressPollMs);
         if (threadShouldExit())
            break;
         if (!mOwner.IsInferInFlight())
            continue;

         std::string host;
         int port;
         {
            const std::lock_guard<ofMutex> lock(mLock);
            host = mHost;
            port = mPort;
         }

         int statusCode = 0;
         juce::URL url("http://" + juce::String(host) + ":" + juce::String(port) + "/progress");
         auto stream = url.createInputStream(
         juce::URL::InputStreamOptions(juce::URL::ParameterHandling::inAddress)
         .withConnectionTimeoutMs(kProgressTimeoutMs)
         .withStatusCode(&statusCode));
         if (stream == nullptr || statusCode != 200)
            continue;

         juce::var p = juce::JSON::parse(stream->readEntireStreamAsString());
         if (p.getProperty("state", juce::var()).toString() != "busy")
            continue;

         juce::var eta = p.getProperty("eta_s", juce::var());
         mOwner.SetProgress(p.getProperty("phase", juce::var()).toString().toStdString(),
                            (int)p.getProperty("step", 0),
                            (int)p.getProperty("total_steps", 0),
                            (float)(double)p.getProperty("elapsed_s", 0.0),
                            eta.isVoid() ? -1.0f : (float)(double)eta);
      }
   }

private:
   ModuleACEResonator& mOwner;
   juce::WaitableEvent mWake;
   ofMutex mLock;
   std::string mHost{ "127.0.0.1" };
   int mPort{ 8976 };
};

// Owns every blocking operation the module needs (health polling, the /infer
// HTTP round-trip, WAV encode/decode, the iterate chain) on a dedicated thread,
// so the audio and UI threads never wait on the network or on inference time.
class ACEBridgeWorker : public juce::Thread
{
public:
   explicit ACEBridgeWorker(ModuleACEResonator& owner)
   : juce::Thread("ACEResonator Bridge Worker")
   , mOwner(owner)
   , mProgressPoller(owner)
   {
      mProgressPoller.startThread();
   }

   ~ACEBridgeWorker() override
   {
      signalThreadShouldExit();
      mWakeEvent.signal();
      stopThread(2000);
   }

   void SetConnection(const std::string& host, int port)
   {
      {
         const std::lock_guard<ofMutex> lock(mConnectionLock);
         mHost = host;
         mPort = port;
      }
      mProgressPoller.SetConnection(host, port);
   }

   void RequestInfer(ACEInferJob&& job)
   {
      {
         const std::lock_guard<ofMutex> lock(mRequestLock);
         mPendingJob = std::move(job);
         mHasPendingInfer = true;
      }
      mWakeEvent.signal();
   }

   // Best-effort graceful shutdown, called directly from the main thread
   // during module teardown, bounded by a short timeout.
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
         ACEInferJob job;
         {
            const std::lock_guard<ofMutex> lock(mRequestLock);
            if (mHasPendingInfer)
            {
               hasWork = true;
               job = std::move(mPendingJob);
               mHasPendingInfer = false;
            }
         }

         if (hasWork)
            DoChain(std::move(job));
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
      juce::URL url("http://" + juce::String(host) + ":" + juce::String(port) + "/status");
      auto stream = url.createInputStream(
      juce::URL::InputStreamOptions(juce::URL::ParameterHandling::inAddress)
      .withConnectionTimeoutMs(kHealthCheckTimeoutMs)
      .withStatusCode(&statusCode));

      if (stream == nullptr || statusCode != 200)
      {
         mOwner.SetBridgeHealthy(false);
         mOwner.SetBridgeInfo("bridge: unreachable at " + host + ":" + std::to_string(port), false);
         return;
      }

      juce::var parsed = juce::JSON::parse(stream->readEntireStreamAsString());
      bool modelLoaded = parsed.getProperty("model_loaded", false);
      juce::String modelType = parsed.getProperty("model_type", juce::var("none")).toString();
      juce::String device = parsed.getProperty("device", juce::var("?")).toString();
      juce::String dtype = parsed.getProperty("dtype", juce::var("?")).toString().replace("torch.", "");
      juce::String error = parsed.getProperty("error", juce::var()).toString();

      std::string info;
      if (modelLoaded)
         info = "bridge: connected | model " + modelType.toStdString() + " | " + dtype.toStdString() + " | " + device.toStdString();
      else
         info = "bridge: connected | NO MODEL LOADED - output is passthrough" + (error.isNotEmpty() ? (" (" + error.toStdString() + ")") : std::string());

      mOwner.SetBridgeHealthy(true);
      mOwner.SetBridgeInfo(info, modelLoaded);
   }

   static bool EncodeWav(const std::vector<float>& audio, int sampleRate, juce::String& base64Out)
   {
      juce::MemoryBlock wavBlock;
      {
         juce::WavAudioFormat wavFormat;
         std::unique_ptr<juce::AudioFormatWriter> writer(wavFormat.createWriterFor(
         new juce::MemoryOutputStream(wavBlock, false), sampleRate, 1u, 32, {}, 0));
         if (writer == nullptr)
            return false;

         const float* channels[] = { audio.data() };
         writer->writeFromFloatArrays(channels, 1, (int)audio.size());
      }
      base64Out = juce::Base64::toBase64(wavBlock.getData(), wavBlock.getSize());
      return true;
   }

   // One /infer round trip. On failure returns false with the reason already
   // in the status line.
   bool DoInferOnce(const ACEInferJob& job, const std::vector<float>& audio, int seed, std::vector<float>& decodedOut, bool& modelUsed)
   {
      juce::String audioBase64;
      if (!EncodeWav(audio, job.sampleRate, audioBase64))
      {
         mOwner.SetStatusMessage("failed to encode snapshot as WAV");
         return false;
      }

      juce::DynamicObject::Ptr requestObj = new juce::DynamicObject();
      requestObj->setProperty("audio", audioBase64);
      requestObj->setProperty("prompt", juce::String(job.prompt));
      requestObj->setProperty("guidance_scale", (double)job.guidance);
      requestObj->setProperty("num_steps", job.steps);
      requestObj->setProperty("seed", seed);
      requestObj->setProperty("input_strength", (double)job.inputStrength);
      // The bridge scales the step count by this (effective = round(steps * value));
      // it is not a wet/dry amount.
      requestObj->setProperty("denoise_strength", (double)job.gamma);
      requestObj->setProperty("audio_duration", (double)audio.size() / job.sampleRate);

      juce::String jsonBody = juce::JSON::toString(juce::var(requestObj.get()), true);

      std::string host;
      int port;
      GetConnection(host, port);

      juce::URL url("http://" + juce::String(host) + ":" + juce::String(port) + "/infer");
      url = url.withPOSTData(jsonBody);

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
         return false;
      }

      juce::var response = juce::JSON::parse(stream->readEntireStreamAsString());

      if (statusCode != 200 || response.hasProperty("error"))
      {
         juce::String message = response.hasProperty("error")
                                ? response["error"].toString()
                                : ("HTTP " + juce::String(statusCode));
         mOwner.SetStatusMessage("inference error: " + message.toStdString());
         return false;
      }

      modelUsed = (bool)response.getProperty("model_used", false);

      juce::MemoryBlock outWavBytes;
      {
         juce::MemoryOutputStream mos(outWavBytes, false);
         if (!juce::Base64::convertFromBase64(mos, response["audio"].toString()))
         {
            mOwner.SetStatusMessage("bridge returned invalid base64 audio");
            return false;
         }
      }

      juce::WavAudioFormat wavFormat;
      std::unique_ptr<juce::AudioFormatReader> reader(
      wavFormat.createReaderFor(new juce::MemoryInputStream(outWavBytes, false), true));

      if (reader == nullptr || reader->lengthInSamples <= 0)
      {
         mOwner.SetStatusMessage("could not decode WAV returned by bridge");
         return false;
      }

      int numSamples = (int)reader->lengthInSamples;
      std::vector<float> decoded(numSamples);
      float* channelPtrs[] = { decoded.data() };
      reader->read(channelPtrs, 1, 0, numSamples);

      // The engine plays at gSampleRate with no resampler in the output path.
      decodedOut = ResampleLinear(decoded, (int)reader->sampleRate, job.sampleRate);
      return true;
   }

   void DoChain(ACEInferJob job)
   {
      std::mt19937 rng((unsigned)job.seed);
      std::normal_distribution<float> normal(0.0f, 1.0f);

      std::vector<float> current = std::move(job.audio);
      int effectiveSteps = std::max(1, (int)std::lround(job.steps * job.gamma));

      for (int i = 0; i < job.iterations; ++i)
      {
         mOwner.SetIteration(i + 1, job.iterations);
         mOwner.ClearProgress();
         mOwner.SetStatusMessage("sending to bridge...");

         // Iteration 0 already carries N(mu,sigma) from the UI thread.
         if (i > 0 && (job.mu != 0.0f || job.sigma != 0.0f))
         {
            for (float& s : current)
               s += job.mu + job.sigma * normal(rng);
         }

         int seed = job.seed + i;
         double t0 = juce::Time::getMillisecondCounterHiRes();
         std::vector<float> take;
         bool modelUsed = false;
         if (!DoInferOnce(job, current, seed, take, modelUsed))
            break;
         double wallSeconds = (juce::Time::getMillisecondCounterHiRes() - t0) / 1000.0;

         if (job.normalize)
         {
            float peak = 0.0f;
            for (float s : take)
               peak = std::max(peak, std::fabs(s));
            if (peak > 1.0e-6f)
            {
               float g = kNormalizeTargetPeak / peak;
               for (float& s : take)
                  s *= g;
            }
         }

         current = take; // this take is S(i+1)
         mOwner.PublishOutputBuffer(std::move(take));
         mOwner.SetBridgeHealthy(true);

         std::string promptShown = Truncate(job.prompt, 40);
         std::string line = "take " + std::to_string(i + 1) + "/" + std::to_string(job.iterations)
                            + " seed=" + std::to_string(seed)
                            + " steps=" + std::to_string(job.steps) + "(eff " + std::to_string(effectiveSteps) + ")"
                            + " cfg=" + FormatFloat(job.guidance, 1)
                            + " strength=" + FormatFloat(job.inputStrength, 2)
                            + " gamma=" + FormatFloat(job.gamma, 2)
                            + " " + FormatFloat((float)wallSeconds, 1) + "s"
                            + (modelUsed ? "" : " PASSTHROUGH")
                            + " prompt='" + promptShown + "'";
         mOwner.SetStatusMessage(line);
         std::fprintf(stdout, "[ACEResonator] %s\n", line.c_str());
         std::fflush(stdout);

         if (mOwner.IsCancelRequested())
         {
            mOwner.SetStatusMessage("cancelled after take " + std::to_string(i + 1) + "/" + std::to_string(job.iterations) + " | " + line);
            break;
         }
      }

      mOwner.ClearProgress();
      mOwner.SetInferInFlight(false);
   }

   ModuleACEResonator& mOwner;
   ACEProgressPoller mProgressPoller;

   juce::WaitableEvent mWakeEvent;

   ofMutex mConnectionLock;
   std::string mHost{ "127.0.0.1" };
   int mPort{ 8976 };

   ofMutex mRequestLock;
   bool mHasPendingInfer{ false };
   ACEInferJob mPendingJob;
};

ModuleACEResonator::ModuleACEResonator()
: IAudioProcessor(gBufferSize)
, IDrawableModule(390, 140)
, mInputSnapshot(int(kMaxSnapshotSeconds * gSampleRate))
, mRandomEngine(std::random_device{}())
{
   SetCString(mScriptPathBuffer, ResolveDefaultScriptPath().toStdString());
   SetCString(mModelPathBuffer, ResolveDefaultModelPath().toStdString());
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
   UIBLOCK(3, 3, 125);
   TEXTENTRY(mPromptEntry, "prompt", 40, mPromptBuffer);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mInputStrengthSlider, "input strength", &mInputStrength, 0, 1);
   UIBLOCK_SHIFTRIGHT();
   INTSLIDER(mStepsSlider, "steps", &mSteps, 1, 30);
   UIBLOCK_SHIFTRIGHT();
   FLOATSLIDER(mGuidanceSlider, "guidance", &mGuidance, 1, 20);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mGammaSlider, "gamma (step scale)", &mGamma, 0, 1);
   UIBLOCK_SHIFTRIGHT();
   FLOATSLIDER(mMuSlider, "noise mu", &mMu, -1, 1);
   UIBLOCK_SHIFTRIGHT();
   FLOATSLIDER(mSigmaSlider, "noise sigma", &mSigma, 0, 1);
   UIBLOCK_NEWLINE();
   TEXTENTRY_NUM(mSeedEntry, "seed (-1 random)", 10, &mSeed, -1, 2000000000);
   UIBLOCK_SHIFTRIGHT();
   CHECKBOX(mLockSeedCheckbox, "lock seed", &mLockSeed);
   UIBLOCK_SHIFTRIGHT();
   INTSLIDER(mIterateSlider, "iterate", &mIterate, 1, 16);
   UIBLOCK_NEWLINE();
   FLOATSLIDER(mDrySlider, "dry monitor", &mDry, 0, 1);
   UIBLOCK_SHIFTRIGHT();
   FLOATSLIDER(mOutGainSlider, "out gain dB", &mOutGainDb, -60, 24);
   UIBLOCK_SHIFTRIGHT();
   CHECKBOX(mNormalizeCheckbox, "normalize take", &mNormalize);
   UIBLOCK_NEWLINE();
   CHECKBOX(mLoopCheckbox, "loop take", &mLoop);
   UIBLOCK_SHIFTRIGHT();
   BUTTON(mTriggerButton, "regenerate");
   UIBLOCK_SHIFTRIGHT();
   BUTTON(mCancelButton, "cancel");
   UIBLOCK_NEWLINE();
   TEXTENTRY(mModelPathEntry, "model path", 40, mModelPathBuffer);
   UIBLOCK_NEWLINE();
   TEXTENTRY(mScriptPathEntry, "bridge script", 34, mScriptPathBuffer);
   UIBLOCK_NEWLINE();
   TEXTENTRY(mHostEntry, "host", 16, mHostBuffer);
   UIBLOCK_SHIFTRIGHT();
   TEXTENTRY_NUM(mPortEntry, "port", 6, &mPort, 1, 65535);
   UIBLOCK_NEWLINE();
   ENDUIBLOCK(mWidth, mHeight);

   mWidth = std::max(mWidth, 400.0f);

   // DrawModule() lays out the progress bar and three text lines below the controls.
   mControlsBottom = mHeight;
   mHeight += 58;
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

   juce::String pythonExecutable = ResolveBridgePythonExecutable(juce::String(mScriptPathBuffer));
   juce::String modelPath(mModelPathBuffer);

   juce::StringArray args;
   args.add(pythonExecutable);
   args.add(juce::String(mScriptPathBuffer));
   args.add("--host");
   args.add(juce::String(mHostBuffer));
   args.add("--port");
   args.add(juce::String(mPort));
   if (modelPath.isNotEmpty())
   {
      args.add("--model-path");
      args.add(modelPath);
   }
   args.add("--device");
   args.add("auto");
   args.add("--warmup");

   mBridgeProcess = new juce::ChildProcess();
   bool success = mBridgeProcess->start(args);
   if (!success)
   {
      ofLog() << "ModuleACEResonator: failed to launch ACE bridge process (tried '" << pythonExecutable << "')";
      SetStatusMessage("failed to launch bridge: '" + pythonExecutable.toStdString() + "' not found");
      delete mBridgeProcess;
      mBridgeProcess = nullptr;
   }
   else if (modelPath.isEmpty())
   {
      SetStatusMessage("no weights configured (set model path or " + std::string(kModelPathEnvVar) + "): bridge runs passthrough");
   }
   else if (!juce::File(modelPath).exists())
   {
      SetStatusMessage("model path does not exist: " + modelPath.toStdString());
   }
   else
   {
      SetStatusMessage("bridge starting, loading weights (first launch takes a while)...");
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

   // Triggers can arrive on the audio thread (pulses); the snapshot copy and
   // allocation happen here instead so the audio thread never allocates.
   if (mTriggerRequested.exchange(false, std::memory_order_acq_rel))
      TriggerRegenerate();
}

void ModuleACEResonator::Process(double time)
{
   PROFILER(ModuleACEResonator);

   IAudioReceiver* target = GetTarget();

   ComputeSliders(0);
   SyncBuffers(1);

   int bufferSize = GetBuffer()->BufferSize();
   assert(bufferSize == gBufferSize);

   float* input = GetBuffer()->GetChannel(0);

   // Continuously record S(i): whatever is coming in now becomes the seed for
   // the next regeneration cycle, whenever the next trigger arrives.
   mInputSnapshot.WriteChunk(input, bufferSize, 0);

   if (mEnabled && target != nullptr)
   {
      int state = mTakeState.load(std::memory_order_acquire);
      int serial = state >> 1;
      int readIndex = state & 1;

      if (serial != mSeenTakeSerial)
      {
         // New take: restart it, and fade from the last emitted sample rather
         // than reading the old buffer, which the worker may soon reuse.
         mSeenTakeSerial = serial;
         mPlaybackPosition = 0;
         mFadeRemaining = kCrossfadeSamples;
      }

      const std::vector<float>& playback = mOutputBuffers[readIndex];
      int length = (serial > 0) ? mOutputLengths[readIndex] : 0;
      bool loop = mLoop;

      float targetGain = (mOutGainDb <= -59.9f) ? 0.0f : std::pow(10.0f, mOutGainDb / 20.0f);
      float dry = mDry;
      float gainStep = (targetGain - mLastGain) / bufferSize;
      float gain = mLastGain;

      for (int i = 0; i < bufferSize; ++i)
      {
         float wet = 0.0f;
         if (length > 0 && mPlaybackPosition < length)
         {
            wet = playback[mPlaybackPosition];
            ++mPlaybackPosition;
            if (mPlaybackPosition >= length && loop)
               mPlaybackPosition = 0;
         }

         if (mFadeRemaining > 0)
         {
            float t = 1.0f - float(mFadeRemaining) / kCrossfadeSamples;
            wet = mLastWetSample + (wet - mLastWetSample) * t;
            --mFadeRemaining;
         }
         mLastWetSample = wet;

         gain += gainStep;
         mPlaybackScratch[i] = wet * gain + dry * input[i];
      }
      mLastGain = targetGain;

      ChannelBuffer* out = target->GetBuffer();
      for (int ch = 0; ch < out->NumActiveChannels(); ++ch)
         Add(out->GetChannel(ch), mPlaybackScratch.data(), bufferSize);

      GetVizBuffer()->WriteChunk(mPlaybackScratch.data(), bufferSize, 0);
   }

   GetBuffer()->Reset();
}

void ModuleACEResonator::OnPulse(double time, float velocity, int flags)
{
   mTriggerRequested.store(true, std::memory_order_release);
}

void ModuleACEResonator::ButtonClicked(ClickButton* button, double time)
{
   if (button == mTriggerButton)
   {
      mTriggerRequested.store(true, std::memory_order_release);
   }
   else if (button == mCancelButton)
   {
      mCancelRequested.store(true, std::memory_order_release);
      if (mInferInFlight.load(std::memory_order_acquire))
         SetStatusMessage("cancel requested: chain stops after the in-flight take");
   }
}

void ModuleACEResonator::TextEntryComplete(TextEntry* entry)
{
   if ((entry == mHostEntry || entry == mPortEntry) && mWorker != nullptr)
      mWorker->SetConnection(mHostBuffer, mPort);

   if ((entry == mModelPathEntry || entry == mScriptPathEntry) && mWorker != nullptr)
      LaunchBridgeProcess(); // weights and script are only read at bridge startup
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
      return; // a chain is already running; drop this trigger rather than queue it up

   mCancelRequested.store(false, std::memory_order_release);
   StartJobFromSnapshot();
}

void ModuleACEResonator::StartJobFromSnapshot()
{
   int snapshotLength = mInputSnapshot.Size();
   mInputSnapshot.ReadChunk(mTriggerScratch.data(), snapshotLength, 0, 0);

   ACEInferJob job;
   job.sampleRate = gSampleRate;
   job.guidance = mGuidance;
   job.steps = mSteps;
   job.inputStrength = mInputStrength;
   job.gamma = mGamma;
   job.mu = mMu;
   job.sigma = mSigma;
   job.prompt = std::string(mPromptBuffer);
   job.iterations = std::max(1, mIterate);
   job.normalize = mNormalize;
   job.durationSeconds = float(snapshotLength) / gSampleRate;

   // The bridge picks its own seed for -1 but doesn't report it, so choose
   // here to be able to log and lock it.
   if (mSeed >= 0)
      job.seed = mSeed;
   else if (mLockSeed && mLastSeed >= 0)
      job.seed = mLastSeed;
   else
      job.seed = (int)(mRandomEngine() % 1000000000u);
   mLastSeed = job.seed;

   // Inject N(mu,sigma) before sending, per S(i+1) = ACE(S(i) + N(mu,sigma), P, gamma):
   // the bridge has no separate noise inputs, so the noise lands in the audio.
   job.audio.resize(snapshotLength);
   for (int i = 0; i < snapshotLength; ++i)
      job.audio[i] = mTriggerScratch[i] + mMu + mSigma * mNormalDist(mRandomEngine);

   SetIteration(1, job.iterations);
   SetStatusMessage("queued");
   mWorker->RequestInfer(std::move(job));
}

void ModuleACEResonator::PublishOutputBuffer(std::vector<float>&& samples)
{
   // Only the worker thread publishes, so a relaxed read of the state is exact.
   // Takes are seconds apart; the audio thread cannot still be inside a
   // callback that read the buffer this overwrites.
   int state = mTakeState.load(std::memory_order_relaxed);
   int backIndex = 1 - (state & 1);
   mOutputBuffers[backIndex] = std::move(samples);
   mOutputLengths[backIndex] = (int)mOutputBuffers[backIndex].size();
   int serial = (state >> 1) + 1;
   mTakeState.store((serial << 1) | backIndex, std::memory_order_release);
}

void ModuleACEResonator::SetStatusMessage(const std::string& message)
{
   const std::lock_guard<ofMutex> lock(mStatusLock);
   mStatusMessage = message;
}

void ModuleACEResonator::SetBridgeInfo(const std::string& info, bool modelLoaded)
{
   mModelLoaded.store(modelLoaded, std::memory_order_release);
   const std::lock_guard<ofMutex> lock(mStatusLock);
   mBridgeInfo = info;
}

void ModuleACEResonator::SetProgress(const std::string& phase, int step, int totalSteps, float elapsedSeconds, float etaSeconds)
{
   const std::lock_guard<ofMutex> lock(mStatusLock);
   mProgressPhase = phase;
   mProgressStep = step;
   mProgressTotal = totalSteps;
   mProgressElapsed = elapsedSeconds;
   mProgressEta = etaSeconds;
}

void ModuleACEResonator::ClearProgress()
{
   SetProgress("", 0, 0, 0, -1);
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
   mInputStrengthSlider->Draw();
   mStepsSlider->Draw();
   mGuidanceSlider->Draw();
   mGammaSlider->Draw();
   mMuSlider->Draw();
   mSigmaSlider->Draw();
   mSeedEntry->Draw();
   mLockSeedCheckbox->Draw();
   mIterateSlider->Draw();
   mDrySlider->Draw();
   mOutGainSlider->Draw();
   mNormalizeCheckbox->Draw();
   mLoopCheckbox->Draw();
   mTriggerButton->Draw();
   mCancelButton->Draw();
   mModelPathEntry->Draw();
   mScriptPathEntry->Draw();
   mHostEntry->Draw();
   mPortEntry->Draw();

   std::string status, bridgeInfo, phase;
   int step, total;
   float elapsed, eta;
   {
      const std::lock_guard<ofMutex> lock(mStatusLock);
      status = mStatusMessage;
      bridgeInfo = mBridgeInfo;
      phase = mProgressPhase;
      step = mProgressStep;
      total = mProgressTotal;
      elapsed = mProgressElapsed;
      eta = mProgressEta;
   }

   bool inFlight = mInferInFlight.load(std::memory_order_acquire);
   int iterCur = mIterationCurrent.load(std::memory_order_relaxed);
   int iterTotal = mIterationTotal.load(std::memory_order_relaxed);

   const float barX = 5;
   const float barW = mWidth - 10;
   const float barY = mControlsBottom + 2;
   const size_t maxChars = (size_t)(barW / 5.4f);

   ofPushStyle();

   ofNoFill();
   ofSetColor(140, 140, 140);
   ofRect(barX, barY, barW, 10);
   if (inFlight)
   {
      float frac = total > 0 ? ofClamp((float)step / total, 0.0f, 1.0f) : 0.0f;
      ofFill();
      ofSetColor(90, 200, 130);
      ofRect(barX, barY, barW * frac, 10);
   }

   ofSetColor(255, 255, 255);
   std::string progressText;
   if (inFlight)
   {
      progressText = phase.empty() ? "working" : phase;
      if (total > 0)
         progressText += "  step " + std::to_string(step) + "/" + std::to_string(total);
      if (eta >= 0)
         progressText += "  eta " + FormatFloat(eta, 1) + "s";
      else if (elapsed > 0)
         progressText += "  " + FormatFloat(elapsed, 1) + "s";
      if (iterTotal > 1)
         progressText += "  |  iteration " + std::to_string(iterCur) + "/" + std::to_string(iterTotal);
   }
   else
   {
      progressText = "idle";
      if (iterTotal > 1)
         progressText += "  |  last chain " + std::to_string(iterCur) + "/" + std::to_string(iterTotal);
   }
   DrawTextNormal(Truncate(progressText, maxChars), barX, barY + 22, 10);
   DrawTextNormal(Truncate(status, maxChars), barX, barY + 34, 10);

   bool warn = !mBridgeHealthy.load(std::memory_order_acquire) || !mModelLoaded.load(std::memory_order_acquire);
   if (warn)
      ofSetColor(255, 170, 90);
   DrawTextNormal(Truncate(bridgeInfo, maxChars), barX, barY + 46, 10);

   ofPopStyle();
}

std::vector<IUIControl*> ModuleACEResonator::ControlsToIgnoreInSaveState() const
{
   return { mModelPathEntry, mScriptPathEntry, mHostEntry, mPortEntry };
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
