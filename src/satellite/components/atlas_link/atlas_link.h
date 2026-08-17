#pragma once

#include <cstring>
#include <string>
#include <vector>

#include "esphome/core/component.h"
#include "esphome/core/log.h"
#include "esphome/components/audio/audio.h"
#include "esphome/components/microphone/microphone.h"
#include "esphome/components/speaker/speaker.h"
#include "esphome/components/switch/switch.h"
#include "esphome/components/respeaker_xvf3800/respeaker_xvf3800.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include <fcntl.h>
#include <math.h>
#include <lwip/netdb.h>
#include <lwip/sockets.h>
#include <lwip/tcp.h>

#include "esp_system.h"
#include "esp_wifi.h"

namespace esphome
{
  namespace atlas_link
  {

    static const char *const TAG = "atlas_link";

    // Wire format: [u32 LE payload_len][u8 type][payload]
    enum FrameType : uint8_t
    {
      FRAME_MIC = 0x01,
      FRAME_TTS = 0x02,
      FRAME_CTRL = 0x03,
      FRAME_EVENT = 0x04
    };
    enum ControlCmd : uint8_t
    {
      CTRL_FLUSH = 0x01,
      CTRL_TTS_START = 0x02,
      CTRL_SET_STATE = 0x03
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

    // Uplink: the forked i2s_audio mic delivers 16 kHz s32 stereo; we extract
    // left-channel s16le. Downlink: 24 kHz s16le mono on the wire (halves the
    // TCP load vs 48 k, and matches Kokoro's native rate); the device upsamples
    // 2x (half-band FIR, polyphase form) to the 48 kHz stereo stream the I2S
    // bus (and XVF3800 AEC reference) requires.
    // TTS frames are dropped unless the gate is open (CTRL_TTS_START opens,
    // CTRL_FLUSH closes + stops speaker), so in-flight frames after a flush
    // cannot restart playback.
    // A full speaker ring means we are AHEAD of playback: drop rather than
    // block. Sends are bounded: a dead peer costs a reconnect, not a wedge.
    // LED ring is rendered locally at 25 Hz from the last received LED state;
    // the speaking envelope is computed from playback samples as they pass.
    // The spinner starts from the last beam direction so listening hands off
    // to thinking without a positional jump. Breathing effects phase from the
    // state-entry timestamp so transitions always start dark.
    static constexpr size_t FRAME_SAMPLES = 320;             // 20 ms @ 16 kHz
    static constexpr size_t FRAME_BYTES = FRAME_SAMPLES * 2; // s16le mono
    static constexpr UBaseType_t TXQ_LEN = 16;
    static constexpr uint32_t SEND_TIMEOUT_MS = 2500;

    static constexpr float kInterpTaps[8] = {
        0.62527244f,
        -0.18021552f,
        0.08021558f,
        -0.03583439f,
        0.01420185f,
        -0.00446061f,
        0.00082065f,
        0.00000000f,
    };

    class AtlasLink : public Component
    {
    public:
      void set_server(std::string host, uint16_t port)
      {
        host_ = std::move(host);
        port_ = port;
      }
      void set_microphone(microphone::Microphone *mic) { mic_ = mic; }
      void set_speaker(speaker::Speaker *spk) { spk_ = spk; }
      void set_debug(bool debug) { debug_ = debug; }
      void set_respeaker(respeaker_xvf3800::RespeakerXVF3800 *respeaker) { respeaker_ = respeaker; }
      void set_mute_switch(switch_::Switch *mute_switch) { mute_switch_ = mute_switch; }
      void set_beam_offset(int offset) { beam_offset_ = offset; }

      float get_setup_priority() const override { return setup_priority::AFTER_WIFI; }

      void setup() override
      {
        // Secondary-mode speaker requires stream sample rate == configured bus rate;
        // nothing upstream sets this for us, so declare it before the first play().
        spk_->set_audio_stream_info(audio::AudioStreamInfo(16, 2, 48000));
        txq_ = xQueueCreate(TXQ_LEN, FRAME_BYTES);
        mic_->add_data_callback([this](const std::vector<uint8_t> &data)
                                { this->on_mic_data_(data); });
        xTaskCreate(task_fn_, "atlas_link", 8192, this, 10, &task_);
      }

      void loop() override
      {
        if (connected_ && !mic_running_)
        {
          mic_->start();
          mic_running_ = true;
        }
        else if (!connected_ && mic_running_)
        {
          mic_->stop();
          mic_running_ = false;
        }
        uint32_t now = millis();
        if (connected_ && last_iter_ != 0 && now - last_iter_ > 2000 && now - last_stall_log_ > 5000)
        {
          last_stall_log_ = now;
          ESP_LOGW(TAG, "socket task stalled for %lu ms (tts_active=%d)",
                   (unsigned long)(now - last_iter_), tts_active_);
        }
        if (now - last_drop_log_ > 5000)
        {
          last_drop_log_ = now;
          if (txdrop_ > 0)
            ESP_LOGW(TAG, "dropped %lu tx frames (queue full)", (unsigned long)txdrop_);
          txdrop_ = 0;
        }
        if (debug_ && now - last_link_log_ > 5000)
        {
          last_link_log_ = now;
          wifi_ap_record_t ap;
          if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK)
          {
            ESP_LOGI(TAG, "link: rssi %d dBm, bssid %02x:%02x:%02x:%02x:%02x:%02x, heap %lu (min %lu)",
                     ap.rssi, ap.bssid[0], ap.bssid[1], ap.bssid[2], ap.bssid[3], ap.bssid[4],
                     ap.bssid[5], (unsigned long)esp_get_free_heap_size(),
                     (unsigned long)esp_get_minimum_free_heap_size());
          }
        }
        if (now - last_led_render_ > 40)
        {
          last_led_render_ = now;
          render_leds_(now);
        }
      }

    protected:
      static void task_fn_(void *arg) { static_cast<AtlasLink *>(arg)->run_(); }

      static uint32_t rgb_(uint8_t r, uint8_t g, uint8_t b)
      {
        return ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
      }

      // One canonical green; everything green is this hue at some brightness.
      static uint32_t green_(float brightness)
      {
        if (brightness < 0)
          brightness = 0;
        if (brightness > 1)
          brightness = 1;
        return rgb_(0, (uint8_t)(200 * brightness), 0);
      }

      void render_leds_(uint32_t now)
      {
        if (respeaker_ == nullptr)
          return;
        uint32_t colors[12] = {0};

        if (mute_switch_ != nullptr && mute_switch_->state)
        {
          for (auto &c : colors)
            c = rgb_(60, 0, 0);
        }
        else if (!connected_)
        {
          float phase = (now - led_state_changed_at_) / 600.0f;
          float b = 0.5f - 0.5f * cosf(phase); // breathe starts from off
          uint8_t v = (uint8_t)(140 * b);
          for (auto &c : colors)
            c = rgb_(v, 0, 0);
        }
        else
        {
          switch (led_state_)
          {
          case LED_IDLE:
            break;
          case LED_CONVO_OPEN:
          {
            float phase = (now - led_state_changed_at_) / 900.0f;
            float b = 0.5f - 0.5f * cosf(phase); // starts from off
            for (auto &c : colors)
              c = green_(0.6f * b);
            break;
          }
          case LED_RECORDING:
          {
            // Beam reads are I2C transactions with internal retries; 12 Hz is
            // plenty for a 30-degree-resolution indicator.
            if (now - last_beam_read_ > 80)
            {
              last_beam_read_ = now;
              int raw = respeaker_->read_led_beam_direction();
              if (raw >= 0 && raw <= 11)
              {
                last_beam_dir_ = (raw + beam_offset_ + 12) % 12;
              }
            }
            int dir = last_beam_dir_;
            if (dir < 0)
            {
              for (auto &c : colors)
                c = green_(0.15f);
            }
            else
            {
              colors[dir] = green_(1.0f);
              colors[(dir + 1) % 12] = colors[(dir + 11) % 12] = green_(0.4f);
              colors[(dir + 2) % 12] = colors[(dir + 10) % 12] = green_(0.15f);
            }
            break;
          }
          case LED_PROCESSING:
          {
            uint32_t steps = (now - led_state_changed_at_) / 100;
            int head = (int)((spinner_origin_ + steps) % 12);
            colors[head] = green_(1.0f);
            colors[(head + 11) % 12] = green_(0.4f);
            colors[(head + 10) % 12] = green_(0.15f);
            break;
          }
          case LED_SPEAKING:
          {
            float e = play_env_ / 0.25f;
            if (e > 1.0f)
              e = 1.0f;
            for (auto &c : colors)
              c = green_(0.15f + 0.85f * e);
            break;
          }
          }
        }
        respeaker_->set_led_ring(colors);
      }

      void run_()
      {
        for (;;)
        {
          if (!connect_())
          {
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
          }
          connected_ = true;
          ESP_LOGI(TAG, "connected to %s:%u", host_.c_str(), port_);
          serve_();
          connected_ = false;
          tts_active_ = false;
          spk_->stop();
          close(sock_);
          sock_ = -1;
          led_state_changed_at_ = millis(); // disconnected breathe starts from off
          ESP_LOGW(TAG, "disconnected");
          vTaskDelay(pdMS_TO_TICKS(500));
        }
      }

      bool connect_()
      {
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port_);
        if (inet_pton(AF_INET, host_.c_str(), &addr.sin_addr) != 1)
        {
          hostent *he = gethostbyname(host_.c_str());
          if (he == nullptr)
            return false;
          memcpy(&addr.sin_addr, he->h_addr, he->h_length);
        }
        // Global scope qualifier: the `api` component pulls in ESPHome's socket
        // component, whose esphome::socket namespace would otherwise shadow this.
        int s = ::socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0)
          return false;
        if (connect(s, (sockaddr *)&addr, sizeof(addr)) != 0)
        {
          close(s);
          return false;
        }
        int one = 1;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
        fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
        sock_ = s;
        return true;
      }

      void serve_()
      {
        uint8_t txbuf[FRAME_BYTES];
        std::vector<uint8_t> rxbuf;
        rxbuf.reserve(65536);
        for (;;)
        {
          last_iter_ = millis();
          maybe_log_stats_();
          if (xQueueReceive(txq_, txbuf, pdMS_TO_TICKS(10)) == pdTRUE)
          {
            micFrames_++;
            if (!send_frame_(FRAME_MIC, txbuf, FRAME_BYTES))
              return;
          }
          // Drain everything available each tick; a single read per tick leaves
          // the receive window closed most of the time and starves the downlink.
          for (;;)
          {
            int n = recv(sock_, rxscratch_, sizeof(rxscratch_), 0);
            if (n > 0)
            {
              rxbuf.insert(rxbuf.end(), rxscratch_, rxscratch_ + n);
              parse_rx_(rxbuf);
            }
            else if (n == 0)
            {
              return;
            }
            else if (errno != EAGAIN)
            {
              return;
            }
            else
            {
              break;
            }
          }
        }
      }

      void maybe_log_stats_()
      {
        uint32_t now = millis();
        if (now - statsStart_ < 2000)
          return;
        if (debug_ && (rxTtsFrames_ > 0 || rxTtsDropped_ > 0 || micFrames_ > 0))
        {
          ESP_LOGI(TAG,
                   "stats: mic tx %lu, tts rx %lu (%lu B), dropped %lu, play blocked %lu ms (max %lu), partial %lu, playdrop %lu",
                   (unsigned long)micFrames_, (unsigned long)rxTtsFrames_, (unsigned long)rxTtsBytes_,
                   (unsigned long)rxTtsDropped_, (unsigned long)playBlockedMs_,
                   (unsigned long)playMaxBlockMs_, (unsigned long)playPartial_,
                   (unsigned long)playDrop_);
        }
        statsStart_ = now;
        micFrames_ = rxTtsFrames_ = 0;
        rxTtsBytes_ = rxTtsDropped_ = playBlockedMs_ = playMaxBlockMs_ = playPartial_ = playDrop_ = 0;
      }

      bool send_frame_(uint8_t type, const uint8_t *payload, uint32_t len)
      {
        uint8_t hdr[5];
        memcpy(hdr, &len, 4); // ESP32 is little-endian
        hdr[4] = type;
        return send_all_(hdr, 5) && (len == 0 || send_all_(payload, len));
      }

      bool send_all_(const uint8_t *data, size_t len)
      {
        size_t off = 0;
        uint32_t t0 = millis();
        while (off < len)
        {
          ssize_t w = send(sock_, data + off, len - off, 0);
          if (w < 0)
          {
            if (errno == EAGAIN)
            {
              if (millis() - t0 > SEND_TIMEOUT_MS)
              {
                ESP_LOGW(TAG, "send timed out; reconnecting");
                return false;
              }
              vTaskDelay(pdMS_TO_TICKS(2));
              continue;
            }
            return false;
          }
          off += w;
        }
        return true;
      }

      void parse_rx_(std::vector<uint8_t> &buf)
      {
        size_t pos = 0;
        for (;;)
        {
          if (buf.size() - pos < 5)
            break;
          uint32_t len;
          memcpy(&len, buf.data() + pos, 4);
          uint8_t type = buf[pos + 4];
          if (len > 65536)
          {
            pos++;
            continue;
          } // resync on garbage length
          if (buf.size() - pos - 5 < len)
            break;
          handle_rx_(type, buf.data() + pos + 5, len);
          pos += 5 + len;
        }
        buf.erase(buf.begin(), buf.begin() + pos);
      }

      void handle_rx_(uint8_t type, const uint8_t *payload, uint32_t len)
      {
        if (type == FRAME_TTS)
        {
          if (!tts_active_)
          {
            rxTtsDropped_++;
            return; // dropped: gate closed (prevents post-flush restart)
          }
          size_t n = len / 2;
          if (n == 0)
            return;
          // 24 kHz s16le mono -> 48 kHz s16le stereo, half-band polyphase FIR.
          // Output lags input by 8 samples (0.33 ms); register zeroed per burst.
          std::vector<int16_t> out(n * 4);
          int32_t frame_peak = 0;
          for (size_t i = 0; i < n; i++)
          {
            int16_t cur;
            memcpy(&cur, payload + 2 * i, 2);
            int32_t a = cur < 0 ? -(int32_t)cur : (int32_t)cur;
            if (a > frame_peak)
              frame_peak = a;
            memmove(&fir_hist_[0], &fir_hist_[1], 15 * sizeof(int16_t));
            fir_hist_[15] = cur;
            float acc = 0;
            for (int k = 0; k < 8; k++)
            {
              acc += kInterpTaps[k] * ((float)fir_hist_[7 - k] + (float)fir_hist_[8 + k]);
            }
            int32_t mid = (int32_t)lrintf(acc);
            if (mid > 32767)
              mid = 32767;
            if (mid < -32768)
              mid = -32768;
            int16_t even = fir_hist_[7];
            out[4 * i] = out[4 * i + 1] = even;
            out[4 * i + 2] = out[4 * i + 3] = (int16_t)mid;
          }
          // Peak-follower envelope (~100 ms decay) for the speaking animation.
          float env = frame_peak / 32768.0f;
          play_env_ = env > play_env_ * 0.85f ? env : play_env_ * 0.85f;
          size_t expected = out.size() * sizeof(int16_t);
          const uint8_t *ptr = (const uint8_t *)out.data();
          size_t written = 0;
          uint32_t t0 = millis();
          while (written < expected)
          {
            size_t w = spk_->play(ptr + written, expected - written);
            if (w == 0)
            {
              if (millis() - t0 > 5)
              {
                // Ring full: we are ahead of playback. Drop the rest of this
                // frame rather than stall the socket task.
                playDrop_++;
                break;
              }
              vTaskDelay(pdMS_TO_TICKS(1));
              continue;
            }
            written += w;
          }
          uint32_t blocked = millis() - t0;
          if (blocked > 50)
            ESP_LOGW(TAG, "play blocked %lu ms", (unsigned long)blocked);
          note_tts_frame_(len, written, expected, blocked);
        }
        else if (type == FRAME_CTRL && len >= 1)
        {
          if (payload[0] == CTRL_FLUSH)
          {
            tts_active_ = false;
            memset(fir_hist_, 0, sizeof(fir_hist_));
            play_env_ = 0;
            spk_->stop();
            if (debug_)
              ESP_LOGI(TAG, "flush: speaker stopped");
            uint8_t ev = EV_FLUSHED;
            send_frame_(FRAME_EVENT, &ev, 1);
          }
          else if (payload[0] == CTRL_TTS_START)
          {
            tts_active_ = true;
            memset(fir_hist_, 0, sizeof(fir_hist_));
            play_env_ = 0;
            if (debug_)
              ESP_LOGI(TAG, "tts start");
          }
          else if (payload[0] == CTRL_SET_STATE && len >= 2)
          {
            led_state_ = payload[1];
            led_state_changed_at_ = millis();
            if (led_state_ == LED_PROCESSING)
            {
              spinner_origin_ = last_beam_dir_ >= 0 ? last_beam_dir_ : 0;
            }
            if (debug_)
              ESP_LOGI(TAG, "led state %d", (int)led_state_);
          }
        }
      }

      void note_tts_frame_(uint32_t payload_len, size_t written, size_t expected, uint32_t blocked_ms)
      {
        rxTtsFrames_++;
        rxTtsBytes_ += payload_len;
        playBlockedMs_ += blocked_ms;
        if (blocked_ms > playMaxBlockMs_)
          playMaxBlockMs_ = blocked_ms;
        if (written != expected)
          playPartial_++;
      }

      void on_mic_data_(const std::vector<uint8_t> &data)
      {
        // 16 kHz s32le stereo interleaved -> left channel s16le (use p + 4 for right)
        const uint8_t *p = data.data();
        size_t n = data.size();
        while (n >= 8)
        {
          int32_t v;
          memcpy(&v, p, 4);
          int16_t s = (int16_t)(v >> 16);
          txacc_[txfill_++] = s & 0xff;
          txacc_[txfill_++] = (uint8_t)(s >> 8);
          p += 8;
          n -= 8;
          if (txfill_ == FRAME_BYTES)
          {
            if (xQueueSend(txq_, txacc_, 0) != pdTRUE)
              txdrop_++;
            txfill_ = 0;
          }
        }
      }

      std::string host_;
      uint16_t port_{0};
      microphone::Microphone *mic_{nullptr};
      speaker::Speaker *spk_{nullptr};
      respeaker_xvf3800::RespeakerXVF3800 *respeaker_{nullptr};
      switch_::Switch *mute_switch_{nullptr};
      int beam_offset_{0};
      int sock_{-1};
      TaskHandle_t task_{nullptr};
      QueueHandle_t txq_{nullptr};
      volatile bool connected_{false};
      volatile uint32_t last_iter_{0};
      bool mic_running_{false};
      bool tts_active_{false};
      bool debug_{false};
      uint8_t txacc_[FRAME_BYTES];
      size_t txfill_{0};
      int16_t fir_hist_[16] = {};
      float play_env_{0};
      uint8_t led_state_{LED_IDLE};
      uint32_t last_led_render_{0};
      uint32_t last_beam_read_{0};
      int last_beam_dir_{-1};
      uint32_t led_state_changed_at_{0};
      int spinner_origin_{0};
      uint32_t txdrop_{0};
      uint32_t last_drop_log_{0};
      uint32_t last_stall_log_{0};
      uint32_t last_link_log_{0};
      uint8_t rxscratch_[4096];
      uint32_t micFrames_{0};
      uint32_t rxTtsFrames_{0};
      uint32_t rxTtsBytes_{0};
      uint32_t rxTtsDropped_{0};
      uint32_t playBlockedMs_{0};
      uint32_t playMaxBlockMs_{0};
      uint32_t playPartial_{0};
      uint32_t playDrop_{0};
      uint32_t statsStart_{0};
    };

  } // namespace atlas_link
} // namespace esphome
