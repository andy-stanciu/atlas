#pragma once

// Atlas satellite link: streams mic audio upstream and TTS/music downstream
// over a raw TCP frame protocol, mixes voice with ducked music into the
// speaker, and renders the LED ring locally.
//
// Uplink: the forked i2s_audio mic delivers 16 kHz s32le stereo; the left
// channel is extracted as s16le. Downlink voice: 24 kHz s16le mono on the
// wire, upsampled 2x (half-band FIR) to the 48 kHz stereo stream the I2S bus
// and the XVF3800 AEC reference require. Downlink music: 48 kHz s16le stereo.
// Output mixing: out = voice + lowpass(music) * duck. The low-pass cutoff
// ramps in lockstep with the duck gain.
//
// Implementation files:
//   atlas_link.cpp          lifecycle, connection, serve loop, stats
//   atlas_link_protocol.cpp frame encode/parse, control handling
//   atlas_link_audio.cpp    mic packing, TTS upsampling, music receive
//   atlas_link_output.cpp   output task: hold, mix, pace, flood guard
//   atlas_link_filter.h     music low-pass (cascaded biquads)
//   atlas_link_led.cpp      LED ring rendering, beam capture

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
      FRAME_MUSIC = 0x05
    };

    // CTRL_MUSIC_DUCK payload: [cmd, gain u8, cutoff_hz u16 LE]; the cutoff is
    // optional (2-byte payloads leave it unchanged).
    enum ControlCmd : uint8_t
    {
      CTRL_FLUSH = 0x01,
      CTRL_TTS_START = 0x02,
      CTRL_SET_STATE = 0x03,
      CTRL_MUSIC_STOP = 0x04,
      CTRL_MUSIC_DUCK = 0x05
    };

    enum EventCode : uint8_t
    {
      EV_FLUSHED = 0x01
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

    // Frame sizes: 20 ms of audio per frame on every path.
    static constexpr size_t FRAME_SAMPLES = 320;             // 20 ms @ 16 kHz
    static constexpr size_t FRAME_BYTES = FRAME_SAMPLES * 2; // s16le mono
    static constexpr size_t MUSIC_BYTES = 3840;              // 20 ms @ 48 kHz s16 stereo

    // Ring capacities, in frames.
    static constexpr size_t VOICE_RING_FRAMES = 12;      // 240 ms
    static constexpr size_t MUSIC_RING_FRAMES = 100;     // 2 s capacity
    static constexpr size_t MUSIC_RING_TRIM_FRAMES = 25; // 500 ms flood trigger

    // Timing (ms). Stream liveness for hold purposes is tight (~3-5 frame
    // periods): a longer window would hold across sentence gaps and starve
    // the speaker ring.
    static constexpr uint32_t MUSIC_IDLE_STOP_MS = 2000; // flush-side liveness
    static constexpr uint32_t VOICE_HOLD_LIVE_MS = 60;   // ~3 frame periods
    static constexpr uint32_t MUSIC_HOLD_LIVE_MS = 100;  // ~5 frame periods
    static constexpr uint32_t MIX_HOLD_MS = 40;
    static constexpr uint32_t OUT_FRAME_MS = 20;
    static constexpr uint32_t SEND_TIMEOUT_MS = 2500;

    // Asymmetric duck ramp: falling fast (barge-in wins in ~80 ms), rising
    // slow (~2.9 s full range) so restores and music fade-ins are gentle.
    static constexpr float DUCK_STEP_DOWN = 0.25f;
    static constexpr float DUCK_STEP_UP = 0.007f;

    static constexpr UBaseType_t TXQ_LEN = 16;

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

      // ---- tasks and transport ----
      int sock_{-1};
      TaskHandle_t task_{nullptr};
      TaskHandle_t out_task_{nullptr};
      QueueHandle_t txq_{nullptr};
      SemaphoreHandle_t spk_mtx_{nullptr};
      portMUX_TYPE ring_mtx_ = portMUX_INITIALIZER_UNLOCKED;
      volatile bool connected_{false};
      volatile uint32_t last_iter_{0};
      bool mic_running_{false};

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
      uint8_t txacc_[FRAME_BYTES]{};
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
      uint32_t last_link_log_{0};
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
    };

  } // namespace atlas_link
} // namespace esphome
