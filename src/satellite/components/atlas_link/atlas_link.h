#pragma once

#include <cstring>
#include <string>
#include <vector>

#include "esphome/core/component.h"
#include "esphome/core/log.h"
#include "esphome/components/audio/audio.h"
#include "esphome/components/microphone/microphone.h"
#include "esphome/components/speaker/speaker.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include <fcntl.h>
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
      CTRL_TTS_START = 0x02
    };
    enum EventCode : uint8_t
    {
      EV_FLUSHED = 0x01
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
    // block. Blocking throttles the socket task, backs up TCP, and lets the
    // device's playback position diverge from the sender's clock by seconds.
    // Sends are bounded: if the peer stops reading, drop the connection and
    // reconnect rather than wedging the audio paths on a dead socket.
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
      }

    protected:
      static void task_fn_(void *arg) { static_cast<AtlasLink *>(arg)->run_(); }

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
          for (size_t i = 0; i < n; i++)
          {
            int16_t cur;
            memcpy(&cur, payload + 2 * i, 2);
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
            if (debug_)
              ESP_LOGI(TAG, "tts start");
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
