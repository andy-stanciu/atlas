#include "atlas_capture.h"

#include <cstring>
#include <math.h>

#include <errno.h>
#include <fcntl.h>
#include <lwip/netdb.h>
#include <lwip/sockets.h>
#include <lwip/tcp.h>

#include "esphome/core/log.h"
#include "esp_heap_caps.h"
#include "esp_wifi.h"

namespace esphome
{
  namespace atlas_capture
  {

    static const char *const TAG = "atlas_capture";

    static uint32_t rgb(uint8_t r, uint8_t g, uint8_t b) { return ((uint32_t)r << 16) | ((uint32_t)g << 8) | b; }

    void AtlasCapture::setup()
    {
      ring_ = (uint8_t *)heap_caps_calloc(RING_FRAMES, FRAME_BYTES, MALLOC_CAP_SPIRAM);
      mic_->add_data_callback([this](const std::vector<uint8_t> &d)
                              { this->on_mic_data_(d); });
      xTaskCreate(task_fn_, "atlas_capture", 8192, this, 10, &task_);
    }

    void AtlasCapture::loop()
    {
      if (!mic_started_)
      {
        mic_->start();
        mic_started_ = true;
      }
      uint32_t now = millis();
      if (now - last_led_ > 40)
      {
        last_led_ = now;
        render_leds_(now);
      }
    }

    void AtlasCapture::task_fn_(void *arg) { static_cast<AtlasCapture *>(arg)->run_(); }

    void AtlasCapture::on_mic_data_(const std::vector<uint8_t> &data)
    {
      // 16 kHz s32le stereo: left = comms channel, right = ASR channel.
      const uint8_t *p = data.data();
      size_t n = data.size();
      while (n >= 8)
      {
        int32_t l, r;
        memcpy(&l, p, 4);
        memcpy(&r, p + 4, 4);
        int16_t sl = (int16_t)(l >> 16), sr = (int16_t)(r >> 16);
        memcpy(acc_ + fill_, &sl, 2);
        memcpy(acc_ + fill_ + 2, &sr, 2);
        fill_ += 4;
        p += 8;
        n -= 8;
        if (fill_ == FRAME_BYTES)
        {
          uint32_t wr = wr_.load(std::memory_order_relaxed);
          memcpy(ring_ + (wr % RING_FRAMES) * FRAME_BYTES, acc_, FRAME_BYTES);
          wr_.store(wr + 1, std::memory_order_release);
          fill_ = 0;
          if (connected_ && task_ != nullptr)
            xTaskNotifyGive(task_);
        }
      }
    }

    void AtlasCapture::run_()
    {
      for (;;)
      {
        if (!connect_())
        {
          vTaskDelay(pdMS_TO_TICKS(1000));
          continue;
        }
        rd_ = wr_.load();
        seq0_ = rd_;
        state_ = ST_IDLE;
        connected_ = true;
        ESP_LOGI(TAG, "connected to %s:%u", host_.c_str(), (unsigned)port_);
        serve_();
        connected_ = false;
        close(sock_);
        sock_ = -1;
        ESP_LOGW(TAG, "disconnected");
        vTaskDelay(pdMS_TO_TICKS(500));
      }
    }

    bool AtlasCapture::connect_()
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

    bool AtlasCapture::send_all_(const uint8_t *data, size_t len)
    {
      size_t off = 0;
      uint32_t t0 = millis();
      while (off < len)
      {
        ssize_t w = send(sock_, data + off, len - off, 0);
        if (w < 0)
        {
          if (errno == EAGAIN && millis() - t0 <= SEND_TIMEOUT_MS)
          {
            vTaskDelay(pdMS_TO_TICKS(2));
            continue;
          }
          ESP_LOGW(TAG, "send failed errno %d", errno);
          return false;
        }
        off += w;
      }
      return true;
    }

    void AtlasCapture::serve_()
    {
      std::vector<uint8_t> rx;
      rx.reserve(256);
      uint8_t scratch[128];
      for (;;)
      {
        for (int sent = 0; sent < PUMP_BURST; sent++)
        {
          uint32_t wr = wr_.load(std::memory_order_acquire);
          uint32_t lag = wr - rd_;
          if (lag == 0)
            break;
          if (lag > RING_FRAMES - 4)
          {
            uint32_t skip = lag - RING_FRAMES / 2;
            frames_skipped_ += skip;
            rd_ += skip;
          }
          uint32_t len = 4 + FRAME_BYTES, seq = rd_ - seq0_;
          memcpy(pkt_, &len, 4);
          pkt_[4] = FRAME_AUDIO;
          memcpy(pkt_ + 5, &seq, 4);
          memcpy(pkt_ + 9, ring_ + (rd_ % RING_FRAMES) * FRAME_BYTES, FRAME_BYTES);
          if (wr_.load(std::memory_order_acquire) - rd_ >= RING_FRAMES)
          {
            frames_skipped_++;
            rd_++;
            continue;
          }
          if (!send_all_(pkt_, PACKET_BYTES))
            return;
          rd_++;
          frames_sent_++;
        }
        if (wr_.load(std::memory_order_acquire) == rd_)
          ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(10));

        for (;;)
        {
          int n = recv(sock_, scratch, sizeof(scratch), 0);
          if (n > 0)
          {
            rx.insert(rx.end(), scratch, scratch + n);
            while (rx.size() >= 5)
            {
              uint32_t len;
              memcpy(&len, rx.data(), 4);
              if (len > 64)
              {
                rx.clear();
                break;
              }
              if (rx.size() < 5 + len)
                break;
              if (rx[4] == FRAME_CTRL && len >= 1)
                handle_ctrl_(rx.data() + 5, len);
              rx.erase(rx.begin(), rx.begin() + 5 + len);
            }
          }
          else if (n == 0)
          {
            ESP_LOGW(TAG, "server closed connection");
            return;
          }
          else if (errno != EAGAIN)
          {
            ESP_LOGW(TAG, "recv error %d", errno);
            return;
          }
          else
            break;
        }

        uint32_t now = millis();
        if (log_stats_ && now - last_stats_ > STATS_MS)
        {
          last_stats_ = now;
          wifi_ap_record_t ap;
          int rssi = esp_wifi_sta_get_ap_info(&ap) == ESP_OK ? ap.rssi : 0;
          ESP_LOGI(TAG, "frames sent %lu skipped %lu rssi %d heap %lu",
                   (unsigned long)frames_sent_, (unsigned long)frames_skipped_, rssi,
                   (unsigned long)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
        }
      }
    }

    void AtlasCapture::handle_ctrl_(const uint8_t *payload, uint32_t len)
    {
      if (payload[0] == CTRL_STATE && len >= 2)
      {
        state_ = payload[1];
        state_since_ = millis();
      }
    }

    void AtlasCapture::render_leds_(uint32_t now)
    {
      if (respeaker_ == nullptr)
        return;
      uint32_t colors[12] = {0};
      uint32_t c = 0;
      float t = (now - state_since_) / 1000.0f;
      float breathe = 0.5f - 0.5f * cosf(now / 700.0f);
      if (!connected_)
        c = rgb((uint8_t)(140 * breathe), 0, 0);
      else
        switch (state_)
        {
        case ST_READY:
          c = rgb(170, 90, 0);
          break;
        case ST_GO:
          c = rgb(0, 220, 0);
          break;
        case ST_DONE:
          c = t < 0.6f ? rgb(0, 60, 220) : 0;
          break;
        case ST_AMBIENT:
          c = rgb((uint8_t)(70 * breathe), 0, (uint8_t)(110 * breathe));
          break;
        default:
          break;
        }
      for (auto &x : colors)
        x = c;
      respeaker_->set_led_ring(colors);
    }

  } // namespace atlas_capture
} // namespace esphome
