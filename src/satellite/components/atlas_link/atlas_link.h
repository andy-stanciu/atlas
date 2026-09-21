#pragma once

#include <cstring>
#include <string>
#include <vector>

#include "esphome/core/component.h"
#include "esphome/core/log.h"
#include "esphome/components/audio/audio.h"
#include "esphome/components/microphone/microphone.h"
#include "esphome/components/speaker/speaker.h"
#include "esphome/components/switch/switch.h"
#include "esphome/components/respeaker_xvf3800/respeaker_xvf3800.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include <fcntl.h>
#include <math.h>
#include <lwip/netdb.h>
#include <lwip/sockets.h>
#include <lwip/tcp.h>

#include "esp_heap_caps.h"
#include "esp_system.h"
#include "esp_wifi.h"

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
      FRAME_EVENT = 0x04,
      FRAME_MUSIC = 0x05
    };
    enum ControlCmd : uint8_t
    {
      CTRL_FLUSH = 0x01,
      CTRL_TTS_START = 0x02,
      CTRL_SET_STATE = 0x03,
      CTRL_MUSIC_STOP = 0x04,
      CTRL_MUSIC_DUCK = 0x05
    };
    enum EventCode : uint8_t
    {
      EV_FLUSHED = 0x01
    };

    // LED states, mirrored by SatelliteLEDState in the Atlas client.
    enum LEDState : uint8_t
    {
      LED_IDLE = 0,
      LED_RECORDING = 1,
      LED_PROCESSING = 2,
      LED_SPEAKING = 3,
      LED_CONVO_OPEN = 4,
    };

    // Uplink: the forked i2s_audio mic delivers 16 kHz s32 stereo; we extract
    // left-channel s16le. Downlink voice: 24 kHz s16le mono on the wire; the
    // device upsamples 2x (half-band FIR, polyphase form) to the 48 kHz stereo
    // stream the I2S bus (and XVF3800 AEC reference) requires. Downlink music:
    // 48 kHz s16le stereo frames (MUSIC_BYTES each), pushed into a deep PSRAM
    // ring.
    // Voice and music are mixed in the output task: out = voice + music * duck.
    // CTRL_MUSIC_DUCK (u8 0..255) sets the target gain; the client's max
    // volume and duck depth are encoded there, so the satellite stays
    // volume-policy-free. The ramp is asymmetric: falling fast (~80 ms full
    // range, barge-in must win immediately), rising slow (~1 s full range,
    // gentle restores).
    // Music fade-in: the gain zeroes on the absent -> live transition of the
    // MUSIC stream (not the speaker's playing flag, which is sticky across
    // cues and speech — the v9 bug where songs started loud). Every track
    // start, track change, and pause-resume has a stream gap and fades in;
    // continuous playback does not.
    // CTRL_FLUSH clears the voice ring only; music keeps playing ducked.
    // The two downlink pacers (TTS bursts, music) jitter against each other by
    // milliseconds; mixing a frame while a live stream's frame is momentarily
    // late zero-pads that stream and chops both at the jitter rate. Before
    // mixing, the task holds up to MIX_HOLD_MS for a late-but-live stream.
    // "Live" for HOLD purposes means the stream's last frame arrived within a
    // few frame periods (VOICE/MUSIC_HOLD_LIVE_MS) — NOT a long window: a
    // long window holds across sentence gaps and after a stream ends,
    // starving the speaker ring.
    // Output rate cap: while playing, the task emits at most one output frame
    // per 20 ms of wall clock. No upstream behavior — client pacing failure,
    // prebuffer floods, bursty TCP — can outrun the DAC; excess music fills
    // the ring and hits the flood guard below instead of the speaker ring.
    // Flood guard: above MUSIC_RING_TRIM_FRAMES (above the largest legitimate
    // TCP burst, below sustained realtime) the task discards contiguous whole
    // frames — a flood becomes a clean forward skip at correct tempo instead
    // of chipmunk chop.
    // The output task NEVER free-runs and NEVER stops the speaker on its own.
    // It drains the rings far faster than the 20 ms frame pace, so empty rings
    // are the steady state between paced frames: the task waits for the next
    // notification instead of padding silence. Only CTRL_FLUSH, teardown and
    // CTRL_MUSIC_STOP-with-voice-idle stop the speaker.
    // EVERY mix pops one frame from each non-empty ring: an undrained ring
    // makes `hm` true forever and the task free-runs on stale buffer contents
    // (the v3 bug).
    // TTS frames are dropped unless the gate is open (CTRL_TTS_START opens,
    // CTRL_FLUSH closes + clears voice), so in-flight frames after a flush
    // cannot restart playback.
    // A full speaker ring means we are AHEAD of playback: drop rather than
    // block. Sends are bounded: a dead peer costs a reconnect, not a wedge.
    // LED ring is rendered locally at 25 Hz from the last received LED state;
    // the speaking envelope is computed from playback samples as they pass.
    // The beam direction is captured at recording START and frozen: the
    // XVF3800's auto-select DoA wanders as speech decays into the endpointing
    // tail, so a direction read at turn end is noise. The spinner inherits the
    // frozen direction. Breathing effects phase from the state-entry timestamp
    // so transitions always start dark.
    // The FIR output buffer is allocated once and reused: per-frame heap churn
    // fragments internal SRAM, which is shared with I2S DMA and lwIP pbufs.
    // spk_->play()/stop() are called only from the output task (and, for stop,
    // from flush/teardown under spk_mtx_): the i2s_audio speaker is not safe
    // for concurrent calls.
    static constexpr size_t FRAME_SAMPLES = 320;             // 20 ms @ 16 kHz
    static constexpr size_t FRAME_BYTES = FRAME_SAMPLES * 2; // s16le mono
    static constexpr size_t MUSIC_BYTES = 3840;              // 20 ms @ 48 kHz s16 stereo
    static constexpr size_t VOICE_RING_FRAMES = 12;          // 240 ms
    static constexpr size_t MUSIC_RING_FRAMES = 100;         // 2 s capacity
    static constexpr size_t MUSIC_RING_TRIM_FRAMES = 25;     // 500 ms flood trigger
    static constexpr uint32_t MUSIC_IDLE_STOP_MS = 2000;     // flush-side liveness
    static constexpr uint32_t VOICE_HOLD_LIVE_MS = 60;       // ~3 frame periods
    static constexpr uint32_t MUSIC_HOLD_LIVE_MS = 100;      // ~5 frame periods
    static constexpr uint32_t MIX_HOLD_MS = 40;
    static constexpr uint32_t OUT_FRAME_MS = 20;
    static constexpr float DUCK_STEP_DOWN = 0.25f; // ~80 ms full range
    static constexpr float DUCK_STEP_UP = 0.007f;  // ~1 s full range
    static constexpr UBaseType_t TXQ_LEN = 16;
    static constexpr uint32_t SEND_TIMEOUT_MS = 2500;

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

    struct AudioRing
    {
      uint8_t *frames = nullptr;
      uint16_t *lens = nullptr;
      size_t capacity = 0;
      volatile size_t count = 0;
      size_t head = 0;

      void alloc(size_t frameCount)
      {
        frames = (uint8_t *)heap_caps_calloc(frameCount, MUSIC_BYTES, MALLOC_CAP_SPIRAM);
        lens = (uint16_t *)heap_caps_calloc(frameCount, sizeof(uint16_t), MALLOC_CAP_SPIRAM);
        capacity = frameCount;
      }

      bool push(const uint8_t *data, size_t len, portMUX_TYPE *mtx)
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

      size_t pop(uint8_t *out, portMUX_TYPE *mtx)
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

      void clear() { count = 0; }
    };

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
      void set_debug(bool debug) { debug_ = debug; }
      void set_respeaker(respeaker_xvf3800::RespeakerXVF3800 *respeaker) { respeaker_ = respeaker; }
      void set_mute_switch(switch_::Switch *mute_switch) { mute_switch_ = mute_switch; }
      void set_beam_offset(int offset) { beam_offset_ = offset; }

      float get_setup_priority() const override { return setup_priority::AFTER_WIFI; }

      void setup() override
      {
        ESP_LOGI(TAG, "atlas_link v10: music-stream fade-in");
        // Secondary-mode speaker requires stream sample rate == configured bus rate;
        // nothing upstream sets this for us, so declare it before the first play().
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

    protected:
      static void task_fn_(void *arg) { static_cast<AtlasLink *>(arg)->run_(); }
      static void out_task_fn_(void *arg) { static_cast<AtlasLink *>(arg)->out_run_(); }

      static uint32_t rgb_(uint8_t r, uint8_t g, uint8_t b)
      {
        return ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
      }

      // One canonical green; everything green is this hue at some brightness.
      static uint32_t green_(float brightness)
      {
        if (brightness < 0)
          brightness = 0;
        if (brightness > 1)
          brightness = 1;
        return rgb_(0, (uint8_t)(200 * brightness), 0);
      }

      void render_leds_(uint32_t now)
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
            // start — the reading is most accurate when speech energy is high
            // and drifts as the utterance tails off.
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

      void capture_beam_()
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
          ESP_LOGI(TAG, "connected to %s:%u (atlas_link v10)", host_.c_str(), (unsigned)port_);
          serve_();
          connected_ = false;
          tts_active_ = false;
          vring_.clear();
          mring_.clear();
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

      void serve_()
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

      void maybe_log_stats_()
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
          {
            rxTtsDropped_++;
            return; // dropped: gate closed (prevents post-flush restart)
          }
          size_t n = len / 2;
          if (n == 0)
            return;
          // 24 kHz s16le mono -> 48 kHz s16le stereo, half-band polyphase FIR.
          // Output lags input by 8 samples (0.33 ms); register zeroed per burst.
          // outbuf_ is grow-once: per-frame heap churn fragments internal SRAM.
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
        else if (type == FRAME_MUSIC)
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
        else if (type == FRAME_CTRL && len >= 1)
        {
          if (payload[0] == CTRL_FLUSH)
          {
            tts_active_ = false;
            memset(fir_hist_, 0, sizeof(fir_hist_));
            play_env_ = 0;
            vring_.clear();
            // Instant voice silence, but never kill ducked music.
            bool musicLive = mring_.count > 0 || millis() - last_music_rx_ < MUSIC_IDLE_STOP_MS;
            if (!musicLive)
              spk_stop_();
            if (debug_)
              ESP_LOGI(TAG, "flush: voice cleared");
            uint8_t ev = EV_FLUSHED;
            send_frame_(FRAME_EVENT, &ev, 1);
          }
          else if (payload[0] == CTRL_TTS_START)
          {
            tts_active_ = true;
            memset(fir_hist_, 0, sizeof(fir_hist_));
            play_env_ = 0;
            if (debug_)
              ESP_LOGI(TAG, "tts start");
          }
          else if (payload[0] == CTRL_SET_STATE && len >= 2)
          {
            led_state_ = payload[1];
            led_state_changed_at_ = millis();
            if (led_state_ == LED_RECORDING)
            {
              // Capture the beam once, at turn start, when the reading is
              // trustworthy; frozen_beam_dir_ drives both the beam indicator
              // and the spinner origin for the rest of the turn.
              capture_beam_();
            }
            else if (led_state_ == LED_PROCESSING)
            {
              spinner_origin_ = frozen_beam_dir_ >= 0 ? frozen_beam_dir_ : 0;
            }
            if (debug_)
            {
              if (led_state_ == LED_PROCESSING)
              {
                ESP_LOGI(TAG, "led state %d (spinner origin %d)", (int)led_state_, spinner_origin_);
              }
              else
              {
                ESP_LOGI(TAG, "led state %d", (int)led_state_);
              }
            }
          }
          else if (payload[0] == CTRL_MUSIC_STOP)
          {
            mring_.clear();
            last_music_rx_ = 0;
            music_was_live_ = false;
            if (vring_.count == 0)
              spk_stop_();
            out_notify_();
          }
          else if (payload[0] == CTRL_MUSIC_DUCK && len >= 2)
          {
            duck_target_ = payload[1] / 255.0f;
          }
        }
      }

      void out_notify_()
      {
        if (out_task_ != nullptr)
          xTaskNotifyGive(out_task_);
      }

      // Asymmetric ramp: falling fast (barge-in wins in ~80 ms), rising slow
      // (~1 s full range) so restores and fade-ins are gentle.
      void duck_step_()
      {
        float d = duck_target_ - duck_prev_;
        if (d > 0)
        {
          if (d > DUCK_STEP_UP)
            d = DUCK_STEP_UP;
        }
        else
        {
          if (-d > DUCK_STEP_DOWN)
            d = -DUCK_STEP_DOWN;
        }
        duck_next_ = duck_prev_ + d;
      }

      size_t spk_play_(const uint8_t *data, size_t len)
      {
        xSemaphoreTake(spk_mtx_, portMAX_DELAY);
        size_t w = spk_->play(data, len);
        xSemaphoreGive(spk_mtx_);
        return w;
      }

      void spk_stop_()
      {
        xSemaphoreTake(spk_mtx_, portMAX_DELAY);
        spk_->stop();
        xSemaphoreGive(spk_mtx_);
        playing_ = false;
        nextOutAt_ = 0;
      }

      void out_run_()
      {
        for (;;)
        {
          ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
          for (;;)
          {
            // Hold briefly when a live stream's frame is momentarily late.
            // Liveness here is tight (~3-5 frame periods): a long window
            // holds across sentence gaps and after stream end, starving
            // the speaker ring.
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
              // Drained: wait for the next frame notification.
              break;
            }

            // Output rate cap: at most one frame per OUT_FRAME_MS of wall
            // clock while playing. No upstream flood can outrun the DAC;
            // excess music accumulates in the ring and is trimmed below.
            uint32_t nowMs = millis();
            if (playing_ && nowMs < nextOutAt_)
            {
              vTaskDelay(pdMS_TO_TICKS(1));
              continue;
            }
            nextOutAt_ = nowMs + OUT_FRAME_MS;

            // Flood guard: pacing failure upstream delivers faster than real
            // time. Trim contiguous whole frames — a clean forward skip
            // instead of chipmunk chop. The threshold sits above the largest
            // legitimate TCP burst and below sustained realtime.
            while (mring_.count >= MUSIC_RING_TRIM_FRAMES)
            {
              if (mring_.pop(musicbuf_, &ring_mtx_) == 0)
                break;
              musicTrimDrop_++;
            }

            hv = vring_.count > 0;
            hm = mring_.count > 0;

            // Music fade-in: zero the gain on the absent -> live transition of
            // the MUSIC stream. The speaker's playing flag is NOT usable here
            // — it is sticky across cues and speech (the v9 bug: songs
            // started loud because a tool cue had played first). Every track
            // start, track change, and pause-resume has a stream gap and
            // fades in; continuous playback does not.
            bool musicLive =
                hm || (millis() - last_music_rx_ < MUSIC_HOLD_LIVE_MS);
            if (musicLive && !music_was_live_)
            {
              duck_prev_ = 0;
            }
            music_was_live_ = musicLive;

            // Pop one frame from each non-empty ring. An undrained ring makes
            // the count check above true forever and the task free-runs on
            // stale buffer contents (the v3 bug).
            size_t voiceLen = hv ? vring_.pop(voicebuf_, &ring_mtx_) : 0;
            size_t musicLen = hm ? mring_.pop(musicbuf_, &ring_mtx_) : 0;
            (void)musicLen;

            duck_step_();
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
              int32_t mixed = voiceSample + (hm ? (int32_t)lrintf(m[i] * gain) : 0);
              o[i] = (int16_t)(mixed > 32767 ? 32767 : (mixed < -32768 ? -32768 : mixed));
              gain += delta;
            }
            duck_prev_ = duck_next_;
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
                  // Ring full: we are ahead of playback. Drop the rest of
                  // this frame rather than stall the output task.
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
      respeaker_xvf3800::RespeakerXVF3800 *respeaker_{nullptr};
      switch_::Switch *mute_switch_{nullptr};
      int beam_offset_{0};
      int sock_{-1};
      TaskHandle_t task_{nullptr};
      TaskHandle_t out_task_{nullptr};
      QueueHandle_t txq_{nullptr};
      SemaphoreHandle_t spk_mtx_{nullptr};
      portMUX_TYPE ring_mtx_ = portMUX_INITIALIZER_UNLOCKED;
      AudioRing vring_;
      AudioRing mring_;
      uint8_t *mixbuf_{nullptr};
      uint8_t *voicebuf_{nullptr};
      uint8_t *musicbuf_{nullptr};
      volatile bool connected_{false};
      volatile uint32_t last_iter_{0};
      bool mic_running_{false};
      bool tts_active_{false};
      bool debug_{false};
      bool playing_{false};
      bool music_was_live_{false};
      uint32_t nextOutAt_{0};
      volatile float duck_target_{1.0f};
      volatile float duck_prev_{1.0f};
      volatile float duck_next_{1.0f};
      volatile uint32_t last_music_rx_{0};
      volatile uint32_t last_voice_rx_{0};
      uint8_t txacc_[FRAME_BYTES];
      size_t txfill_;
      int16_t fir_hist_[16] = {};
      std::vector<int16_t> outbuf_;
      float play_env_{0};
      uint8_t led_state_{LED_IDLE};
      uint32_t last_led_render_{0};
      int frozen_beam_dir_{-1};
      uint32_t led_state_changed_at_{0};
      int spinner_origin_{0};
      uint32_t txdrop_{0};
      uint32_t last_drop_log_{0};
      uint32_t last_stall_log_{0};
      uint32_t last_link_log_{0};
      uint8_t rxscratch_[4096];
      uint32_t micFrames_{0};
      uint32_t rxTtsFrames_{0};
      uint32_t rxTtsBytes_{0};
      uint32_t rxTtsDropped_{0};
      uint32_t playDrop_{0};
      uint32_t musicFrames_{0};
      uint32_t musicDrop_{0};
      uint32_t musicBad_{0};
      uint32_t musicTrimDrop_{0};
      uint32_t statsStart_{0};
    };

  } // namespace atlas_link
} // namespace esphome
