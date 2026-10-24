#pragma once

// Recorder firmware component: streams the XVF3800's two processed channels
// (left = comms, right = ASR) as 16 kHz stereo s16le to a capture server on the
// Mac and shows server-driven LED prompts. Wake word and Atlas link are absent.
//
// Wire format (little-endian), same framing as atlas_link: [u32 len][u8 type][payload]
//   satellite -> server  FRAME_AUDIO: [u32 seq][FRAME_BYTES of stereo s16le], 20 ms
//   server -> satellite  FRAME_CTRL : [CTRL_STATE, state]

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

#include "esphome/core/component.h"
#include "esphome/components/microphone/microphone.h"
#include "esphome/components/respeaker_xvf3800/respeaker_xvf3800.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

namespace esphome
{
  namespace atlas_capture
  {

    enum FrameType : uint8_t
    {
      FRAME_AUDIO = 0x01,
      FRAME_CTRL = 0x03
    };
    enum Ctrl : uint8_t
    {
      CTRL_STATE = 0x01
    };
    enum State : uint8_t
    {
      ST_IDLE = 0,
      ST_READY = 1,
      ST_GO = 2,
      ST_DONE = 3,
      ST_AMBIENT = 4
    };

    static constexpr size_t FRAME_SAMPLES = 320;
    static constexpr size_t FRAME_BYTES = FRAME_SAMPLES * 2 * 2;
    static constexpr size_t PACKET_BYTES = 5 + 4 + FRAME_BYTES;
    static constexpr size_t RING_FRAMES = 128;
    static constexpr int PUMP_BURST = 8;
    static constexpr uint32_t SEND_TIMEOUT_MS = 2500;
    static constexpr uint32_t STATS_MS = 5000;

    class AtlasCapture : public Component
    {
    public:
      void set_server(std::string host, uint16_t port)
      {
        host_ = std::move(host);
        port_ = port;
      }
      void set_microphone(microphone::Microphone *mic) { mic_ = mic; }
      void set_respeaker(respeaker_xvf3800::RespeakerXVF3800 *r) { respeaker_ = r; }
      void set_log_stats(bool v) { log_stats_ = v; }

      float get_setup_priority() const override { return setup_priority::AFTER_WIFI; }
      void setup() override;
      void loop() override;

    protected:
      static void task_fn_(void *arg);
      void run_();
      bool connect_();
      void serve_();
      bool send_all_(const uint8_t *data, size_t len);
      void on_mic_data_(const std::vector<uint8_t> &data);
      void handle_ctrl_(const uint8_t *payload, uint32_t len);
      void render_leds_(uint32_t now);

      std::string host_;
      uint16_t port_{0};
      microphone::Microphone *mic_{nullptr};
      respeaker_xvf3800::RespeakerXVF3800 *respeaker_{nullptr};
      bool log_stats_{false};
      bool mic_started_{false};

      int sock_{-1};
      TaskHandle_t task_{nullptr};
      volatile bool connected_{false};

      uint8_t *ring_{nullptr};
      std::atomic<uint32_t> wr_{0};
      uint32_t rd_{0};
      uint32_t seq0_{0};
      uint8_t acc_[FRAME_BYTES]{};
      size_t fill_{0};
      uint8_t pkt_[PACKET_BYTES]{};

      volatile uint8_t state_{ST_IDLE};
      volatile uint32_t state_since_{0};
      uint32_t last_led_{0};
      uint32_t frames_sent_{0};
      uint32_t frames_skipped_{0};
      uint32_t last_stats_{0};
    };

  } // namespace atlas_capture
} // namespace esphome
