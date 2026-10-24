#pragma once

// Atlas satellite link: streams mic audio upstream and TTS/music downstream
// over a raw TCP frame protocol, mixes voice with ducked music into the
// speaker, and renders the LED ring locally.
//
// Uplink: the forked i2s_audio mic delivers 16 kHz s32le stereo; the left
// channel is extracted as s16le into a PSRAM ring that runs continuously.
// Nothing is sent while idle: a wake word (or a host CTRL_LISTEN hold) opens
// the stream, and a wake replays WAKE_PREROLL_FRAMES of ring history first.
// Downlink voice: 24 kHz s16le mono on the
// wire, upsampled 2x (half-band FIR) to the 48 kHz stereo stream the I2S bus
// and the XVF3800 AEC reference require. Downlink music: 48 kHz s16le stereo.
// Output mixing: out = voice + lowpass(music) * duck. The low-pass cutoff
// ramps in lockstep with the duck gain.
//
// Logging toggles (YAML): log_stats (periodic stats line), log_stalls (gap
// warnings), log_events (connect/disconnect, uplink open/close). `debug`
// is the default for all three. Errors always log.
//
// Implementation files:
//   atlas_link.cpp          lifecycle, connection, serve loop, stats
//   atlas_link_protocol.cpp frame encode/parse, control handling
//   atlas_link_audio.cpp    mic packing, TTS upsampling, music receive
//   atlas_link_wake.cpp     wake gating, uplink stream open/close, mic pump
//   atlas_link_output.cpp   output task: hold, mix, pace, flood guard
//   atlas_link_filter.h     music low-pass (cascaded biquads)
//   atlas_link_led.cpp      LED ring rendering, beam capture

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

#include "esphome/core/component.h"
#include "esphome/components/audio/audio.h"
#include "esphome/components/microphone/microphone.h"
#include "esphome/components/speaker/speaker.h"
#include "esphome/components/switch/switch.h"
#include "esphome/components/respeaker_xvf3800/respeaker_xvf3800.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "atlas_link_filter.h"

namespace esphome
{
  namespace atlas_link
  {

    static const char *const TAG = "atlas_link";

    // ---- Wire protocol ----

    // Frame layout: [u32 LE payload_len][u8 type][payload]
    enum FrameType : uint8_t
    {
      FRAME_MIC = 0x01,
      FRAME_TTS = 0x02,
      FRAME_CTRL = 0x03,
      FRAME_EVENT = 0x04,
      FRAME_MUSIC = 0x05,
      FRAME_MIC2 = 0x06
    };

    // CTRL_MUSIC_DUCK payload: [cmd, gain u8, cutoff_hz u16 LE]; the cutoff is
    // optional (2-byte payloads leave it unchanged).
    // CTRL_LISTEN payload: [cmd, hold u8]; 1 holds the uplink open (wake
    // detection suppressed), 0 closes it and re-arms wake detection.
    enum ControlCmd : uint8_t
    {
      CTRL_FLUSH = 0x01,
      CTRL_TTS_START = 0x02,
      CTRL_SET_STATE = 0x03,
      CTRL_MUSIC_STOP = 0x04,
      CTRL_MUSIC_DUCK = 0x05,
      CTRL_LISTEN = 0x06
    };

    enum EventCode : uint8_t
    {
      EV_FLUSHED = 0x01,
      EV_WAKE = 0x02
    };

    // LED states, mirrored by SatelliteLEDState in the Atlas client.
    enum LEDState : uint8_t
    {
      LED_IDLE = 0,
      LED_RECORDING = 1,
      LED_PROCESSING = 2,
      LED_SPEAKING = 3,
      LED_CONVO_OPEN = 4,
    };

    // ---- Constants ----

    static constexpr size_t MIC_STT_CHANNEL = 1;
    static constexpr int32_t MIC_STT_GAIN_Q8 = 256;

    // Frame sizes: 20 ms of audio per frame on every path.
    static constexpr size_t FRAME_SAMPLES = 320;             // 20 ms @ 16 kHz
    static constexpr size_t FRAME_BYTES = FRAME_SAMPLES * 2; // s16le mono
    static constexpr size_t MIC_FRAME_BYTES = FRAME_BYTES * 2; // s16le stereo: [stt, vad]
    static constexpr size_t MIC_VAD_CHANNEL = 0;               // 0 = left (comms), 1 = right (ASR)
    static constexpr size_t MUSIC_BYTES = 3840;              // 20 ms @ 48 kHz s16 stereo

    // Largest legitimate downlink payload is MUSIC_BYTES; anything bigger is
    // a corrupt header and must not size the receive buffer.
    static constexpr uint32_t MAX_RX_FRAME_BYTES = 8192;
    static constexpr size_t RX_BUFFER_RESERVE = 8192;

    // Ring capacities, in frames.
    static constexpr size_t VOICE_RING_FRAMES = 12;      // 240 ms
    static constexpr size_t MUSIC_RING_FRAMES = 100;     // 2 s capacity
    static constexpr size_t MUSIC_RING_TRIM_FRAMES = 25; // 500 ms flood trigger
    static constexpr size_t MIC_RING_FRAMES = 128;

    // Wake uplink.
    static constexpr size_t WAKE_PREROLL_FRAMES = 75;
    static constexpr uint32_t WAKE_OPEN_TIMEOUT_MS = 10000; // host must hold or close
    static constexpr uint32_t WAKE_HOLDOFF_MS = 1500;       // ignore wakes after close
    static constexpr int MIC_PUMP_BURST = 8;

    // Timing (ms). Stream liveness for hold purposes is tight (~3-5 frame
    // periods): a longer window would hold across sentence gaps and starve
    // the speaker ring.
    static constexpr uint32_t MUSIC_IDLE_STOP_MS = 2000; // flush-side liveness
    static constexpr uint32_t VOICE_HOLD_LIVE_MS = 60;   // ~3 frame periods
    static constexpr uint32_t MUSIC_HOLD_LIVE_MS = 100;  // ~5 frame periods
    static constexpr uint32_t MIX_HOLD_MS = 40;
    static constexpr uint32_t OUT_FRAME_MS = 20;
    static constexpr uint32_t SPK_START_WAIT_MS = 250;
    static constexpr uint32_t SPK_WRITE_WAIT_MS = 5;
    static constexpr uint32_t SEND_TIMEOUT_MS = 2500;

    // Diagnostics thresholds (ms).
    static constexpr uint32_t DIAG_STATS_MS = 2000;
    static constexpr uint32_t DIAG_IDLE_STATS_MS = 30000;
    static constexpr uint32_t DIAG_MUSIC_GAP_WARN_MS = 150;
    static constexpr uint32_t DIAG_OUT_GAP_MS = 45;
    static constexpr uint32_t DIAG_OUT_GAP_WARN_MS = 100;
    static constexpr uint32_t DIAG_MAIN_GAP_WARN_MS = 300;
    static constexpr uint32_t DIAG_WARN_INTERVAL_MS = 1000;

    // Asymmetric duck ramp: falling fast (barge-in wins in ~80 ms), rising
    // slow (~5s full range) so restores and music fade-ins are gentle.
    static constexpr float DUCK_STEP_DOWN = 0.25f;
    static constexpr float DUCK_STEP_UP = 0.0025f;

    static_assert(WAKE_PREROLL_FRAMES + 4 <= MIC_RING_FRAMES && WAKE_PREROLL_FRAMES < 256, "preroll exceeds mic ring");

    // PSRAM frame ring. Push/pop/clear are serialized by the caller's
    // spinlock. The slot freed by pop is only reused after a full ring wrap,
    // so the memcpy in pop may safely run outside the critical section.
    struct AudioRing
    {
      uint8_t *frames = nullptr;
      uint16_t *lens = nullptr;
      size_t capacity = 0;
      volatile size_t count = 0;
      size_t head = 0;

      void alloc(size_t frame_count);
      bool push(const uint8_t *data, size_t len, portMUX_TYPE *mtx);
      size_t pop(uint8_t *out, portMUX_TYPE *mtx);
      void clear(portMUX_TYPE *mtx);
    };

    class AtlasLink : public Component
    {
    public:
      void set_server(std::string host, uint16_t port);
      void set_microphone(microphone::Microphone *mic) { mic_ = mic; }
      void set_speaker(speaker::Speaker *spk) { spk_ = spk; }
      void set_respeaker(respeaker_xvf3800::RespeakerXVF3800 *respeaker) { respeaker_ = respeaker; }
      void set_mute_switch(switch_::Switch *mute_switch) { mute_switch_ = mute_switch; }
      void set_beam_offset(int offset) { beam_offset_ = offset; }
      void set_debug(bool debug) { debug_ = debug; }
      void set_log_stats(bool v) { log_stats_ = v; }
      void set_log_stalls(bool v) { log_stalls_ = v; }
      void set_log_events(bool v) { log_events_ = v; }

      // Wake word callback; safe from any task.
      void on_wake();

      float get_setup_priority() const override;
      void setup() override;
      void loop() override;

    protected:
      static void task_fn_(void *arg);
      static void out_task_fn_(void *arg);

      // ---- atlas_link.cpp: connection lifecycle ----

      // Reconnect loop: connect, serve until the peer drops, tear down cleanly.
      void run_();
      bool connect_();
      void serve_();
      void maybe_log_stats_();

      // ---- atlas_link_protocol.cpp: frame wire format ----

      // Sends are bounded: a dead peer costs a reconnect, not a wedge.
      bool send_frame_(uint8_t type, const uint8_t *payload, uint32_t len);
      bool send_all_(const uint8_t *data, size_t len);
      void parse_rx_(std::vector<uint8_t> &buf);
      void handle_rx_(uint8_t type, const uint8_t *payload, uint32_t len);
      void handle_ctrl_(const uint8_t *payload, uint32_t len);
      void out_notify_();

      // ---- atlas_link_audio.cpp: audio streams ----

      // Uplink mic callback; TTS/music downlink frame handlers.
      void on_mic_data_(const std::vector<uint8_t> &data);
      void handle_tts_(const uint8_t *payload, uint32_t len);
      void handle_music_(const uint8_t *payload, uint32_t len);

      // ---- atlas_link_wake.cpp: wake gating and uplink ----

      void open_stream_(bool woke);
      void hold_stream_();
      void close_stream_();
      bool pump_mic_();

      // ---- atlas_link_output.cpp: output task ----

      // Mix task: holds briefly for late-but-live streams, pops one frame
      // from each non-empty ring, applies the duck ramp, writes to the
      // speaker. Never free-runs and never stops the speaker on its own.
      void out_run_();
      void duck_step_();
      size_t spk_play_(const uint8_t *data, size_t len);
      void spk_stop_();

      // ---- atlas_link_led.cpp: LED ring ----

      static uint32_t rgb_(uint8_t r, uint8_t g, uint8_t b);
      static uint32_t green_(float brightness);
      void render_leds_(uint32_t now);
      void capture_beam_();

      // ---- configuration ----
      std::string host_;
      uint16_t port_{0};
      microphone::Microphone *mic_{nullptr};
      speaker::Speaker *spk_{nullptr};
      respeaker_xvf3800::RespeakerXVF3800 *respeaker_{nullptr};
      switch_::Switch *mute_switch_{nullptr};
      int beam_offset_{0};
      bool debug_{false};
      bool log_stats_{false};
      bool log_stalls_{false};
      bool log_events_{false};

      // ---- tasks and transport ----
      int sock_{-1};
      TaskHandle_t task_{nullptr};
      TaskHandle_t out_task_{nullptr};
      SemaphoreHandle_t spk_mtx_{nullptr};
      portMUX_TYPE ring_mtx_ = portMUX_INITIALIZER_UNLOCKED;
      volatile bool connected_{false};
      volatile uint32_t last_iter_{0};
      bool mic_running_{false};

      // ---- uplink / wake state ----
      // mic_wr_ is single-writer (mic callback); mic_rd_, stream_deadline_
      // and streaming_ transitions belong to the socket task.
      uint8_t *micring_{nullptr};
      std::atomic<uint32_t> mic_wr_{0};
      uint32_t mic_rd_{0};
      std::atomic<bool> streaming_{false};
      std::atomic<bool> wake_req_{false};
      std::atomic<bool> wake_led_pending_{false};
      std::atomic<uint32_t> wake_holdoff_until_{0};
      uint32_t stream_deadline_{0};
      uint8_t wake_replay_{0};

      // ---- audio state (volatile where written cross-task) ----
      AudioRing vring_;
      AudioRing mring_;
      uint8_t *mixbuf_{nullptr};
      uint8_t *voicebuf_{nullptr};
      uint8_t *musicbuf_{nullptr};
      bool tts_active_{false};
      bool playing_{false};
      bool music_was_live_{false};
      uint32_t nextOutAt_{0};
      volatile float duck_target_{1.0f};
      volatile float duck_prev_{1.0f};
      volatile float duck_next_{1.0f};
      volatile float lp_target_{LOWPASS_OPEN_HZ};
      float lp_prev_{LOWPASS_OPEN_HZ};
      float lp_next_{LOWPASS_OPEN_HZ};
      StereoLowPass lp_;
      volatile uint32_t last_music_rx_{0};
      volatile uint32_t last_voice_rx_{0};
      uint8_t txacc_[MIC_FRAME_BYTES]{};
      size_t txfill_{0};
      int16_t fir_hist_[16] = {};
      std::vector<int16_t> outbuf_;
      float play_env_{0};

      // ---- LED state ----
      uint8_t led_state_{LED_IDLE};
      uint32_t last_led_render_{0};
      int frozen_beam_dir_{-1};
      uint32_t led_state_changed_at_{0};
      int spinner_origin_{0};

      // ---- diagnostics ----
      uint8_t rxscratch_[4096];
      uint32_t txdrop_{0};
      uint32_t last_drop_log_{0};
      uint32_t last_stall_log_{0};
      uint32_t last_idle_log_{0};
      uint32_t micFrames_{0};
      uint32_t rxTtsFrames_{0};
      uint32_t rxTtsBytes_{0};
      uint32_t rxTtsDropped_{0};
      uint32_t playDrop_{0};
      uint32_t musicFrames_{0};
      uint32_t musicDrop_{0};
      uint32_t musicBad_{0};
      uint32_t musicTrimDrop_{0};
      uint32_t statsStart_{0};
      uint32_t diagRxBytes_{0};
      uint32_t last_music_gap_log_{0};
      uint32_t last_out_gap_log_{0};
      uint32_t last_main_loop_{0};
      uint32_t last_main_warn_{0};
      volatile uint32_t diagMusicGapMax_{0};
      volatile uint32_t diagServeMax_{0};
      volatile uint32_t diagMainMax_{0};
      volatile uint32_t diagRingMin_{0xFFFFFFFF};
      volatile uint32_t diagRingMax_{0};
      volatile uint32_t diagOutGaps_{0};
      volatile uint32_t diagOutGapMax_{0};
      volatile uint32_t diagSpkFull_{0};
      volatile uint32_t diagSpkWriteMax_{0};
      volatile uint32_t diagLastMusicOut_{0};
    };

  } // namespace atlas_link
} // namespace esphome
