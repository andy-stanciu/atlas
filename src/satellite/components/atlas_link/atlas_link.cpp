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
      ESP_LOGI(TAG, "atlas_link v12: wake-gated uplink");
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
      micring_ = (uint8_t *)heap_caps_calloc(MIC_RING_FRAMES, MIC_FRAME_BYTES, MALLOC_CAP_SPIRAM);
      mic_->add_data_callback([this](const std::vector<uint8_t> &data)
                              { this->on_mic_data_(data); });
      xTaskCreate(task_fn_, "atlas_link", 8192, this, 10, &task_);
      xTaskCreate(out_task_fn_, "atlas_out", 6144, this, 10, &out_task_);
    }

    void AtlasLink::loop()
    {
      if (!mic_running_)
      {
        mic_->start();
        mic_running_ = true;
      }
      if (wake_led_pending_.exchange(false))
      {
        if (respeaker_ != nullptr)
          capture_beam_();
        led_state_ = LED_RECORDING;
        led_state_changed_at_ = millis();
      }
      uint32_t now = millis();
      if (last_main_loop_ != 0)
      {
        uint32_t gap = now - last_main_loop_;
        if (gap > diagMainMax_)
          diagMainMax_ = gap;
        if (log_stalls_ && gap > DIAG_MAIN_GAP_WARN_MS && now - last_main_warn_ > DIAG_WARN_INTERVAL_MS)
        {
          last_main_warn_ = now;
          ESP_LOGW(TAG, "main loop gap %lu ms", (unsigned long)gap);
        }
      }
      last_main_loop_ = now;
      if (log_stalls_ && connected_ && last_iter_ != 0 && now - last_iter_ > 2000 && now - last_stall_log_ > 5000)
      {
        last_stall_log_ = now;
        ESP_LOGW(TAG, "socket task stalled for %lu ms (tts_active=%d)",
                 (unsigned long)(now - last_iter_), tts_active_);
      }
      if (now - last_drop_log_ > 5000)
      {
        last_drop_log_ = now;
        if (txdrop_ > 0)
          ESP_LOGW(TAG, "dropped %lu uplink frames (ring overrun)", (unsigned long)txdrop_);
        txdrop_ = 0;
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
        streaming_ = false;
        wake_req_ = false;
        stream_deadline_ = 0;
        mic_rd_ = mic_wr_.load();
        last_music_rx_ = 0;
        diagLastMusicOut_ = 0;
        connected_ = true;
        if (log_events_)
          ESP_LOGI(TAG, "connected to %s:%u (atlas_link v12), largest internal block %lu",
                   host_.c_str(), (unsigned)port_,
                   (unsigned long)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
        serve_();
        connected_ = false;
        last_iter_ = 0;
        streaming_ = false;
        wake_req_ = false;
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
        if (log_events_)
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
      uint32_t t0 = millis();
      if (connect(s, (sockaddr *)&addr, sizeof(addr)) != 0)
      {
        if (log_events_)
          ESP_LOGW(TAG, "connect failed errno %d after %lu ms", errno, (unsigned long)(millis() - t0));
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
      std::vector<uint8_t> rxbuf;
      rxbuf.reserve(RX_BUFFER_RESERVE);
      for (;;)
      {
        last_iter_ = millis();
        maybe_log_stats_();
        if (wake_req_.exchange(false))
        {
          open_stream_(true);
          uint8_t ev[2] = {EV_WAKE, wake_replay_};
          if (!send_frame_(FRAME_EVENT, ev, 2))
            return;
        }
        if (streaming_)
        {
          if (stream_deadline_ != 0 && (int32_t)(millis() - stream_deadline_) >= 0)
            close_stream_();
          else if (!pump_mic_())
            return;
        }
        bool backlog = streaming_ && mic_wr_.load(std::memory_order_acquire) != mic_rd_;
        if (!backlog)
          ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(10));
        uint32_t busyStart = millis();
        // Drain everything available each tick; a single read per tick leaves
        // the receive window closed most of the time and starves the downlink.
        for (;;)
        {
          int n = recv(sock_, rxscratch_, sizeof(rxscratch_), 0);
          if (n > 0)
          {
            diagRxBytes_ += n;
            rxbuf.insert(rxbuf.end(), rxscratch_, rxscratch_ + n);
            parse_rx_(rxbuf);
          }
          else if (n == 0)
          {
            ESP_LOGW(TAG, "peer closed connection");
            return;
          }
          else if (errno != EAGAIN)
          {
            ESP_LOGW(TAG, "recv error %d", errno);
            return;
          }
          else
          {
            break;
          }
        }
        uint32_t busy = millis() - busyStart;
        if (busy > diagServeMax_)
          diagServeMax_ = busy;
      }
    }

    void AtlasLink::maybe_log_stats_()
    {
      uint32_t now = millis();
      if (now - statsStart_ < DIAG_STATS_MS)
        return;
      bool active = rxTtsFrames_ > 0 || rxTtsDropped_ > 0 || micFrames_ > 0 || musicFrames_ > 0 || musicDrop_ > 0 || diagOutGaps_ > 0;
      if (log_stats_ && (active || now - last_idle_log_ > DIAG_IDLE_STATS_MS))
      {
        last_idle_log_ = now;
        wifi_ap_record_t ap;
        int rssi = 0;
        unsigned bssid5 = 0;
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK)
        {
          rssi = ap.rssi;
          bssid5 = ap.bssid[5];
        }
        uint32_t rmin = diagRingMin_ == 0xFFFFFFFF ? 0 : diagRingMin_;
        ESP_LOGI(TAG,
                 "stats %lums | music rx %lu gap-max %lums ring %lu..%lu trim %lu drop %lu"
                 " | out gaps %lu max %lums spk-full %lu wr-max %lums"
                 " | tts rx %lu pdrop %lu | mic tx %lu | serve-max %lums main-max %lums rx %luB"
                 " | rssi %d bssid ..%02x | heap %lu min %lu dma %lu",
                 (unsigned long)(now - statsStart_),
                 (unsigned long)musicFrames_, (unsigned long)diagMusicGapMax_,
                 (unsigned long)rmin, (unsigned long)diagRingMax_,
                 (unsigned long)musicTrimDrop_, (unsigned long)musicDrop_,
                 (unsigned long)diagOutGaps_, (unsigned long)diagOutGapMax_,
                 (unsigned long)diagSpkFull_, (unsigned long)diagSpkWriteMax_,
                 (unsigned long)rxTtsFrames_, (unsigned long)playDrop_, (unsigned long)micFrames_,
                 (unsigned long)diagServeMax_, (unsigned long)diagMainMax_, (unsigned long)diagRxBytes_,
                 rssi, bssid5,
                 (unsigned long)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                 (unsigned long)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL),
                 (unsigned long)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA));
      }
      statsStart_ = now;
      micFrames_ = rxTtsFrames_ = 0;
      rxTtsBytes_ = rxTtsDropped_ = playDrop_ = 0;
      musicFrames_ = musicDrop_ = musicBad_ = musicTrimDrop_ = 0;
      diagRxBytes_ = 0;
      diagMusicGapMax_ = diagServeMax_ = diagMainMax_ = 0;
      diagRingMin_ = 0xFFFFFFFF;
      diagRingMax_ = 0;
      diagOutGaps_ = diagOutGapMax_ = diagSpkFull_ = diagSpkWriteMax_ = 0;
    }

  } // namespace atlas_link
} // namespace esphome
