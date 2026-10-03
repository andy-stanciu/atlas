#pragma once
#include <math.h>

namespace esphome
{
  namespace atlas_link
  {
    static constexpr float LOWPASS_OPEN_HZ = 20000.0f;
    static constexpr float LOWPASS_MIN_HZ = 50.0f;

    class StereoLowPass
    {
    public:
      void set_cutoff(float hz)
      {
        static constexpr float Q[2] = {0.5412f, 1.3065f};
        float w = 2.0f * (float)M_PI * fminf(fmaxf(hz, LOWPASS_MIN_HZ), LOWPASS_OPEN_HZ) / 48000.0f;
        float c = cosf(w);
        for (int s = 0; s < 2; s++)
        {
          float al = sinf(w) / (2.0f * Q[s]), n = 1.0f / (1.0f + al);
          c_[s].b1 = (1.0f - c) * n;
          c_[s].b0 = c_[s].b2 = c_[s].b1 * 0.5f;
          c_[s].a1 = -2.0f * c * n;
          c_[s].a2 = (1.0f - al) * n;
        }
      }

      float process(float x, int ch)
      {
        for (int s = 0; s < 2; s++)
        {
          float y = c_[s].b0 * x + z_[s][ch][0];
          z_[s][ch][0] = c_[s].b1 * x - c_[s].a1 * y + z_[s][ch][1];
          z_[s][ch][1] = c_[s].b2 * x - c_[s].a2 * y;
          x = y;
        }
        return x;
      }

    private:
      struct Coef
      {
        float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
      };
      Coef c_[2];
      float z_[2][2][2] = {};
    };

  } // namespace atlas_link
} // namespace esphome
