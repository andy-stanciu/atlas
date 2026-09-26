#include "atlas_link.h"

#include <cstring>
#include <math.h>

#include "esphome/core/log.h"

namespace esphome
{
  namespace atlas_link
  {

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

    void AtlasLink::on_mic_data_(const std::vector<uint8_t> &data)
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

    void AtlasLink::handle_tts_(const uint8_t *payload, uint32_t len)
    {
      if (!tts_active_)
      {
        rxTtsDropped_++; // gate closed: post-flush frames cannot restart playback
        return;
      }
      size_t n = len / 2;
      if (n == 0)
        return;
      // 24 kHz s16le mono -> 48 kHz s16le stereo, half-band polyphase FIR.
      // Output lags input by 8 samples (0.33 ms); fir_hist_ is zeroed per
      // burst. outbuf_ grows once: per-frame heap churn fragments internal
      // SRAM, which is shared with I2S DMA and lwIP pbufs.
      outbuf_.resize(n * 4);
      int16_t *out = outbuf_.data();
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
      size_t expected = outbuf_.size() * sizeof(int16_t);
      rxTtsFrames_++;
      rxTtsBytes_ += len;
      if (vring_.push((const uint8_t *)out, expected, &ring_mtx_))
      {
        last_voice_rx_ = millis();
        out_notify_();
      }
      else
        playDrop_++;
    }

    void AtlasLink::handle_music_(const uint8_t *payload, uint32_t len)
    {
      if (len != MUSIC_BYTES)
      {
        musicBad_++;
        return;
      }
      if (mring_.push(payload, len, &ring_mtx_))
      {
        musicFrames_++;
        last_music_rx_ = millis();
        out_notify_();
      }
      else
      {
        musicDrop_++;
      }
    }

  } // namespace atlas_link
} // namespace esphome
