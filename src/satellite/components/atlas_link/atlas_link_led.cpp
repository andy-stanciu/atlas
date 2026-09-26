#include "atlas_link.h"

#include <math.h>

#include "esphome/core/log.h"

namespace esphome
{
  namespace atlas_link
  {

    uint32_t AtlasLink::rgb_(uint8_t r, uint8_t g, uint8_t b)
    {
      return ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
    }

    // One canonical green; everything green is this hue at some brightness.
    uint32_t AtlasLink::green_(float brightness)
    {
      if (brightness < 0)
        brightness = 0;
      if (brightness > 1)
        brightness = 1;
      return rgb_(0, (uint8_t)(200 * brightness), 0);
    }

    // Rendered locally at 25 Hz from the last received LED state. Breathing
    // effects phase from the state-entry timestamp so transitions always
    // start dark.
    void AtlasLink::render_leds_(uint32_t now)
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
          // The beam indicator shows the direction captured at recording
          // start; the DoA reading drifts as the utterance tails off.
          int dir = frozen_beam_dir_;
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

    void AtlasLink::capture_beam_()
    {
      int raw = respeaker_->read_led_beam_direction();
      if (raw >= 0 && raw <= 11)
      {
        int dir = (raw + beam_offset_ + 12) % 12;
        if (debug_ && dir != frozen_beam_dir_)
        {
          ESP_LOGI(TAG, "beam dir %d", dir);
        }
        frozen_beam_dir_ = dir;
      }
    }

  } // namespace atlas_link
} // namespace esphome
