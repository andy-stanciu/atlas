#include "atlas_link.h"

#include <cstring>

#include <errno.h>
#include <lwip/sockets.h>

#include "esphome/core/log.h"

namespace esphome
{
  namespace atlas_link
  {

    void AtlasLink::out_notify_()
    {
      if (out_task_ != nullptr)
        xTaskNotifyGive(out_task_);
    }

    bool AtlasLink::send_frame_(uint8_t type, const uint8_t *payload, uint32_t len)
    {
      uint8_t hdr[5];
      memcpy(hdr, &len, 4); // ESP32 is little-endian
      hdr[4] = type;
      return send_all_(hdr, 5) && (len == 0 || send_all_(payload, len));
    }

    bool AtlasLink::send_all_(const uint8_t *data, size_t len)
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

    void AtlasLink::parse_rx_(std::vector<uint8_t> &buf)
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
          pos++; // resync on garbage length
          continue;
        }
        if (buf.size() - pos - 5 < len)
          break;
        handle_rx_(type, buf.data() + pos + 5, len);
        pos += 5 + len;
      }
      buf.erase(buf.begin(), buf.begin() + pos);
    }

    void AtlasLink::handle_rx_(uint8_t type, const uint8_t *payload, uint32_t len)
    {
      switch (type)
      {
      case FRAME_TTS:
        handle_tts_(payload, len);
        break;
      case FRAME_MUSIC:
        handle_music_(payload, len);
        break;
      case FRAME_CTRL:
        if (len >= 1)
          handle_ctrl_(payload, len);
        break;
      default:
        break;
      }
    }

    void AtlasLink::handle_ctrl_(const uint8_t *payload, uint32_t len)
    {
      switch (payload[0])
      {
      case CTRL_FLUSH:
      {
        // Closes the TTS gate and clears the voice ring only; music keeps
        // playing ducked. The gate prevents in-flight TTS frames after the
        // flush from restarting playback.
        tts_active_ = false;
        memset(fir_hist_, 0, sizeof(fir_hist_));
        play_env_ = 0;
        vring_.clear(&ring_mtx_);
        bool musicLive = mring_.count > 0 || millis() - last_music_rx_ < MUSIC_IDLE_STOP_MS;
        if (!musicLive)
          spk_stop_();
        if (debug_)
          ESP_LOGI(TAG, "flush: voice cleared");
        uint8_t ev = EV_FLUSHED;
        send_frame_(FRAME_EVENT, &ev, 1);
        break;
      }
      case CTRL_TTS_START:
        tts_active_ = true;
        memset(fir_hist_, 0, sizeof(fir_hist_));
        play_env_ = 0;
        if (debug_)
          ESP_LOGI(TAG, "tts start");
        break;
      case CTRL_SET_STATE:
        if (len < 2)
          break;
        led_state_ = payload[1];
        led_state_changed_at_ = millis();
        if (led_state_ == LED_RECORDING)
        {
          // Capture the beam once, at turn start, when the DoA reading is
          // trustworthy; frozen_beam_dir_ drives both the beam indicator and
          // the spinner origin for the rest of the turn.
          capture_beam_();
        }
        else if (led_state_ == LED_PROCESSING)
        {
          spinner_origin_ = frozen_beam_dir_ >= 0 ? frozen_beam_dir_ : 0;
        }
        if (debug_)
        {
          if (led_state_ == LED_PROCESSING)
            ESP_LOGI(TAG, "led state %d (spinner origin %d)", (int)led_state_, spinner_origin_);
          else
            ESP_LOGI(TAG, "led state %d", (int)led_state_);
        }
        break;
      case CTRL_MUSIC_STOP:
        mring_.clear(&ring_mtx_);
        last_music_rx_ = 0;
        music_was_live_ = false;
        if (vring_.count == 0)
          spk_stop_();
        out_notify_();
        break;
      case CTRL_MUSIC_DUCK:
        if (len >= 2)
          duck_target_ = payload[1] / 255.0f;
        break;
      default:
        break;
      }
    }

  } // namespace atlas_link
} // namespace esphome
