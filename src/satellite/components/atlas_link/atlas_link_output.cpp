#include "atlas_link.h"

#include <math.h>

namespace esphome
{
  namespace atlas_link
  {

    // Asymmetric ramp: falling fast (barge-in wins in ~80 ms), rising slow
    // (~2.9 s full range) so restores and fade-ins are gentle. The low-pass
    // cutoff moves the same fraction of its remaining (log) distance as the
    // gain does, so both ramps start and finish together.
    void AtlasLink::duck_step_()
    {
      float remain = duck_target_ - duck_prev_;
      float d = remain > 0 ? fminf(remain, DUCK_STEP_UP) : fmaxf(remain, -DUCK_STEP_DOWN);
      duck_next_ = duck_prev_ + d;
      float frac = fabsf(remain) > 1e-6f ? d / remain : 1.0f;
      float target = lp_target_;
      lp_next_ = frac >= 1.0f ? target : lp_prev_ * powf(target / lp_prev_, frac);
    }

    size_t AtlasLink::spk_play_(const uint8_t *data, size_t len)
    {
      xSemaphoreTake(spk_mtx_, portMAX_DELAY);
      size_t w = spk_->play(data, len);
      xSemaphoreGive(spk_mtx_);
      return w;
    }

    void AtlasLink::spk_stop_()
    {
      xSemaphoreTake(spk_mtx_, portMAX_DELAY);
      spk_->stop();
      xSemaphoreGive(spk_mtx_);
      playing_ = false;
      nextOutAt_ = 0;
    }

    void AtlasLink::out_run_()
    {
      for (;;)
      {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        for (;;)
        {
          // Hold briefly when a live stream's frame is momentarily late; the
          // two downlink pacers (TTS bursts, music) jitter against each other
          // by milliseconds, and mixing while a live stream is late zero-pads
          // it and chops both at the jitter rate.
          uint32_t holdStart = millis();
          for (;;)
          {
            bool hvNow = vring_.count > 0;
            bool hmNow = mring_.count > 0;
            bool voiceWaiting =
                !hvNow && millis() - last_voice_rx_ < VOICE_HOLD_LIVE_MS;
            bool musicWaiting =
                !hmNow && millis() - last_music_rx_ < MUSIC_HOLD_LIVE_MS;
            bool needHold = (hvNow && musicWaiting) ||
                            (hmNow && voiceWaiting) ||
                            (voiceWaiting && musicWaiting);
            if (!needHold || millis() - holdStart > MIX_HOLD_MS)
              break;
            vTaskDelay(pdMS_TO_TICKS(1));
          }

          bool hv = vring_.count > 0;
          bool hm = mring_.count > 0;

          if (!hv && !hm)
          {
            // Drained: wait for the next frame notification. The task drains
            // the rings far faster than the 20 ms frame pace, so empty rings
            // are the steady state between paced frames.
            break;
          }

          // Output rate cap: at most one frame per OUT_FRAME_MS of wall
          // clock while playing. No upstream behavior — client pacing
          // failure, prebuffer floods, bursty TCP — can outrun the DAC;
          // excess music accumulates in the ring and is trimmed below.
          uint32_t nowMs = millis();
          if (playing_ && nowMs < nextOutAt_)
          {
            vTaskDelay(pdMS_TO_TICKS(1));
            continue;
          }
          nextOutAt_ = nowMs + OUT_FRAME_MS;

          // Flood guard: above MUSIC_RING_TRIM_FRAMES (above the largest
          // legitimate TCP burst, below sustained realtime) discard
          // contiguous whole frames — a flood becomes a clean forward skip
          // at correct tempo instead of chipmunk chop.
          while (mring_.count >= MUSIC_RING_TRIM_FRAMES)
          {
            if (mring_.pop(musicbuf_, &ring_mtx_) == 0)
              break;
            musicTrimDrop_++;
          }

          hv = vring_.count > 0;
          hm = mring_.count > 0;

          // Music fade-in: zero the gain on the absent -> live transition of
          // the MUSIC stream (not the speaker's playing flag, which is
          // sticky across cues and speech). Every track start, track
          // change, and pause-resume has a stream gap and fades in;
          // continuous playback does not.
          bool musicLive =
              hm || (millis() - last_music_rx_ < MUSIC_HOLD_LIVE_MS);
          if (musicLive && !music_was_live_)
          {
            duck_prev_ = 0;
          }
          music_was_live_ = musicLive;

          // Pop one frame from each non-empty ring; an undrained ring would
          // make the drained check above true forever and free-run the task
          // on stale buffer contents.
          size_t voiceLen = hv ? vring_.pop(voicebuf_, &ring_mtx_) : 0;
          size_t musicLen = hm ? mring_.pop(musicbuf_, &ring_mtx_) : 0;
          (void)musicLen;

          duck_step_();
          lp_.set_cutoff(lp_next_);
          bool lpActive = lp_next_ < LOWPASS_OPEN_HZ;
          int16_t *v = (int16_t *)voicebuf_;
          int16_t *m = (int16_t *)musicbuf_;
          int16_t *o = (int16_t *)mixbuf_;
          size_t voiceSamples = voiceLen / 2;
          size_t total = MUSIC_BYTES / 2;
          float delta = (duck_next_ - duck_prev_) / (float)total;
          float gain = duck_prev_;
          int32_t peak = 0;
          for (size_t i = 0; i < total; i++)
          {
            int32_t voiceSample = 0;
            if (i < voiceSamples)
            {
              voiceSample = v[i];
              int32_t a = voiceSample < 0 ? -voiceSample : voiceSample;
              if (a > peak)
                peak = a;
            }
            float ms = 0;
            if (hm)
            {
              float f = lp_.process(m[i], i & 1);
              ms = lpActive ? f : m[i];
            }
            int32_t mixed = voiceSample + (int32_t)lrintf(ms * gain);
            o[i] = (int16_t)(mixed > 32767 ? 32767 : (mixed < -32768 ? -32768 : mixed));
            gain += delta;
          }
          duck_prev_ = duck_next_;
          lp_prev_ = lp_next_;
          if (voiceLen > 0)
          {
            float env = peak / 32768.0f;
            play_env_ = env > play_env_ * 0.85f ? env : play_env_ * 0.85f;
          }

          size_t written = 0;
          uint32_t t0 = millis();
          while (written < MUSIC_BYTES)
          {
            size_t w = spk_play_(mixbuf_ + written, MUSIC_BYTES - written);
            if (w == 0)
            {
              if (millis() - t0 > 5)
              {
                // Speaker ring full: we are ahead of playback. Drop the
                // rest of this frame rather than stall the output task.
                playDrop_++;
                break;
              }
              vTaskDelay(pdMS_TO_TICKS(1));
              continue;
            }
            written += w;
          }
          playing_ = true;
        }
      }
    }

  } // namespace atlas_link
} // namespace esphome
