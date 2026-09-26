#include "atlas_link.h"

#include <cstring>

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
  namespace atlas_link
  {

    void AudioRing::alloc(size_t frame_count)
    {
      frames = (uint8_t *)heap_caps_calloc(frame_count, MUSIC_BYTES, MALLOC_CAP_SPIRAM);
      lens = (uint16_t *)heap_caps_calloc(frame_count, sizeof(uint16_t), MALLOC_CAP_SPIRAM);
      capacity = frame_count;
    }

    bool AudioRing::push(const uint8_t *data, size_t len, portMUX_TYPE *mtx)
    {
      portENTER_CRITICAL(mtx);
      if (count == capacity || len > MUSIC_BYTES)
      {
        portEXIT_CRITICAL(mtx);
        return false;
      }
      memcpy(frames + head * MUSIC_BYTES, data, len);
      lens[head] = (uint16_t)len;
      head = (head + 1) % capacity;
      count++;
      portEXIT_CRITICAL(mtx);
      return true;
    }

    size_t AudioRing::pop(uint8_t *out, portMUX_TYPE *mtx)
    {
      portENTER_CRITICAL(mtx);
      if (count == 0)
      {
        portEXIT_CRITICAL(mtx);
        return 0;
      }
      size_t tail = (head + capacity - count) % capacity;
      size_t len = lens[tail];
      count--;
      portEXIT_CRITICAL(mtx);
      memcpy(out, frames + tail * MUSIC_BYTES, len);
      return len;
    }

    void AudioRing::clear(portMUX_TYPE *mtx)
    {
      portENTER_CRITICAL(mtx);
      count = 0;
      portEXIT_CRITICAL(mtx);
    }

    void AtlasLink::task_fn_(void *arg) { static_cast<AtlasLink *>(arg)->run_(); }
    void AtlasLink::out_task_fn_(void *arg) { static_cast<AtlasLink *>(arg)->out_run_(); }

    float AtlasLink::get_setup_priority() const { return setup_priority::AFTER_WIFI; }

    void AtlasLink::setup()
    {
      ESP_LOGI(TAG, "atlas_link v11: module split");
      // Secondary-mode speaker requires stream sample rate == configured bus
      // rate; nothing upstream sets this for us, so declare it before the
      // first play().
      spk_->set_audio_stream_info(audio::AudioStreamInfo(16, 2, 48000));
      spk_mtx_ = xSemaphoreCreateMutex();
      vring_.alloc(VOICE_RING_FRAMES);
      mring_.alloc(MUSIC_RING_FRAMES);
      mixbuf_ = (uint8_t *)heap_caps_malloc(MUSIC_BYTES, MALLOC_CAP_SPIRAM);
      voicebuf_ = (uint8_t *)heap_caps_malloc(MUSIC_BYTES, MALLOC_CAP_SPIRAM);
      musicbuf_ = (uint8_t *)heap_caps_malloc(MUSIC_BYTES, MALLOC_CAP_SPIRAM);
      txq_ = xQueueCreate(TXQ_LEN, FRAME_BYTES);
      mic_->add_data_callback([this](const std::vector<uint8_t> &data)
                              { this->on_mic_data_(data); });
      xTaskCreate(task_fn_, "atlas_link", 8192, this, 10, &task_);
      xTaskCreate(out_task_fn_, "atlas_out", 6144, this, 10, &out_task_);
    }

    void AtlasLink::loop()
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
          // Internal SRAM is the scarce pool (I2S DMA, WiFi, lwIP pbufs);
          // PSRAM totals are irrelevant to the failures we chase here.
          ESP_LOGI(TAG, "link: rssi %d dBm, bssid %02x:%02x:%02x:%02x:%02x:%02x, "
                        "heap-int %lu (min %lu), dma-block %lu",
                   ap.rssi, ap.bssid[0], ap.bssid[1], ap.bssid[2], ap.bssid[3], ap.bssid[4],
                   ap.bssid[5], (unsigned long)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                   (unsigned long)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL),
                   (unsigned long)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA));
        }
      }
      if (now - last_led_render_ > 40)
      {
        last_led_render_ = now;
        render_leds_(now);
      }
    }

    void AtlasLink::run_()
    {
      for (;;)
      {
        if (!connect_())
        {
          vTaskDelay(pdMS_TO_TICKS(1000));
          continue;
        }
        connected_ = true;
        ESP_LOGI(TAG, "connected to %s:%u (atlas_link v11)", host_.c_str(), (unsigned)port_);
        serve_();
        connected_ = false;
        tts_active_ = false;
        vring_.clear(&ring_mtx_);
        mring_.clear(&ring_mtx_);
        last_music_rx_ = 0;
        last_voice_rx_ = 0;
        nextOutAt_ = 0;
        music_was_live_ = false;
        spk_stop_();
        close(sock_);
        sock_ = -1;
        led_state_changed_at_ = millis(); // disconnected breathe starts from off
        ESP_LOGW(TAG, "disconnected");
        vTaskDelay(pdMS_TO_TICKS(500));
      }
    }

    bool AtlasLink::connect_()
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

    void AtlasLink::set_server(std::string host, uint16_t port)
    {
      host_ = std::move(host);
      port_ = port;
    }

    void AtlasLink::serve_()
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

    void AtlasLink::maybe_log_stats_()
    {
      uint32_t now = millis();
      if (now - statsStart_ < 2000)
        return;
      if (debug_ && (rxTtsFrames_ > 0 || rxTtsDropped_ > 0 || micFrames_ > 0 || musicFrames_ > 0 || musicDrop_ > 0))
      {
        ESP_LOGI(TAG,
                 "stats: mic tx %lu, tts rx %lu (%lu B), dropped %lu, playdrop %lu, "
                 "music %lu (drop %lu, bad %lu, trim %lu)",
                 (unsigned long)micFrames_, (unsigned long)rxTtsFrames_, (unsigned long)rxTtsBytes_,
                 (unsigned long)rxTtsDropped_, (unsigned long)playDrop_,
                 (unsigned long)musicFrames_, (unsigned long)musicDrop_,
                 (unsigned long)musicBad_, (unsigned long)musicTrimDrop_);
      }
      statsStart_ = now;
      micFrames_ = rxTtsFrames_ = 0;
      rxTtsBytes_ = rxTtsDropped_ = playDrop_ = 0;
      musicFrames_ = musicDrop_ = musicBad_ = musicTrimDrop_ = 0;
    }

  } // namespace atlas_link
} // namespace esphome
