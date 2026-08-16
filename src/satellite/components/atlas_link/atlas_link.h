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
    // left-channel s16le. Downlink: 48 kHz s16le mono -> s16le stereo; the driver
    // clocks the 16-bit stream into the configured 32-bit I2S slots.
    // TTS frames are dropped unless the gate is open (CTRL_TTS_START opens,
    // CTRL_FLUSH closes + stops speaker), so in-flight frames after a flush
    // cannot restart playback.
    static constexpr size_t FRAME_SAMPLES = 320;             // 20 ms @ 16 kHz
    static constexpr size_t FRAME_BYTES = FRAME_SAMPLES * 2; // s16le mono
    static constexpr UBaseType_t TXQ_LEN = 16;

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
        if (now - last_drop_log_ > 5000)
        {
          last_drop_log_ = now;
          if (txdrop_ > 0)
            ESP_LOGW(TAG, "dropped %lu tx frames (queue full)", (unsigned long)txdrop_);
          txdrop_ = 0;
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
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0)
          return false;
        if (connect(s, (sockaddr *)&addr, sizeof(addr)) != 0)
        {
          close(s);
          return false;
        }
        int one = 1;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
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
          if (xQueueReceive(txq_, txbuf, pdMS_TO_TICKS(10)) == pdTRUE)
          {
            if (!send_frame_(FRAME_MIC, txbuf, FRAME_BYTES))
              return;
          }
          int n = recv(sock_, rxscratch_, sizeof(rxscratch_), 0);
          if (n == 0 || (n < 0 && errno != EAGAIN))
            return;
          if (n > 0)
          {
            rxbuf.insert(rxbuf.end(), rxscratch_, rxscratch_ + n);
            parse_rx_(rxbuf);
          }
        }
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
        while (off < len)
        {
          ssize_t w = send(sock_, data + off, len - off, 0);
          if (w < 0)
          {
            if (errno == EAGAIN)
            {
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
            return; // dropped: gate closed (prevents post-flush restart)
          // 48 kHz s16le mono -> s16le stereo (duplicate channels)
          size_t samples = len / 2;
          std::vector<int16_t> out(samples * 2);
          for (size_t i = 0; i < samples; i++)
          {
            int16_t s;
            memcpy(&s, payload + 2 * i, 2);
            out[2 * i] = out[2 * i + 1] = s;
          }
          spk_->play((const uint8_t *)out.data(), out.size() * sizeof(int16_t));
        }
        else if (type == FRAME_CTRL && len >= 1)
        {
          if (payload[0] == CTRL_FLUSH)
          {
            tts_active_ = false;
            spk_->stop();
            uint8_t ev = EV_FLUSHED;
            send_frame_(FRAME_EVENT, &ev, 1);
          }
          else if (payload[0] == CTRL_TTS_START)
          {
            tts_active_ = true;
          }
        }
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
      bool mic_running_{false};
      bool tts_active_{false};
      uint8_t txacc_[FRAME_BYTES];
      size_t txfill_{0};
      uint32_t txdrop_{0};
      uint32_t last_drop_log_{0};
      uint8_t rxscratch_[4096];
    };

  } // namespace atlas_link
} // namespace esphome
