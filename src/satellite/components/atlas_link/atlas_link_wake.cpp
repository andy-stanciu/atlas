#include "atlas_link.h"

#include <algorithm>
#include <cstring>

#include "esphome/core/log.h"

namespace esphome
{
  namespace atlas_link
  {

    void AtlasLink::on_wake()
    {
      if (!connected_ || streaming_ || wake_req_ || (int32_t)(millis() - wake_holdoff_until_) < 0)
        return;
      wake_req_ = true;
      if (task_ != nullptr)
        xTaskNotifyGive(task_);
    }

    void AtlasLink::open_stream_(bool woke)
    {
      uint32_t wr = mic_wr_.load(std::memory_order_acquire);
      uint32_t back = woke ? std::min<uint32_t>(WAKE_PREROLL_FRAMES, wr) : 0;
      wake_replay_ = woke ? (uint8_t)back : 0;
      mic_rd_ = wr - back;
      stream_deadline_ = woke ? millis() + WAKE_OPEN_TIMEOUT_MS : 0;
      streaming_ = true;
      if (woke)
        wake_led_pending_ = true;
      if (log_events_)
        ESP_LOGI(TAG, "uplink open (%s, preroll %lu frames)", woke ? "wake" : "host", (unsigned long)back);
    }

    void AtlasLink::hold_stream_()
    {
      if (streaming_)
        stream_deadline_ = 0;
      else
        open_stream_(false);
    }

    void AtlasLink::close_stream_()
    {
      bool was = streaming_;
      streaming_ = false;
      stream_deadline_ = 0;
      wake_holdoff_until_ = millis() + WAKE_HOLDOFF_MS;
      led_state_ = LED_IDLE;
      led_state_changed_at_ = millis();
      if (was && log_events_)
        ESP_LOGI(TAG, "uplink closed");
    }

    bool AtlasLink::pump_mic_()
    {
      uint8_t buf[FRAME_BYTES];
      for (int i = 0; i < MIC_PUMP_BURST; i++)
      {
        uint32_t wr = mic_wr_.load(std::memory_order_acquire);
        uint32_t lag = wr - mic_rd_;
        if (lag == 0)
          return true;
        if (lag > MIC_RING_FRAMES - 4)
        {
          uint32_t skip = lag - MIC_RING_FRAMES / 2;
          txdrop_ += skip;
          mic_rd_ += skip;
        }
        memcpy(buf, micring_ + (mic_rd_ % MIC_RING_FRAMES) * FRAME_BYTES, FRAME_BYTES);
        if (mic_wr_.load(std::memory_order_acquire) - mic_rd_ >= MIC_RING_FRAMES)
        {
          txdrop_++;
          mic_rd_++;
          continue;
        }
        if (!send_frame_(FRAME_MIC, buf, FRAME_BYTES))
          return false;
        mic_rd_++;
        micFrames_++;
      }
      return true;
    }

  } // namespace atlas_link
} // namespace esphome
