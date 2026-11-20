// Preparação do áudio para o modelo da palavra "Klaus" (microWakeWord).
//
// Usa o MESMO código do treino (TFLite Micro audio frontend, via pymicro-features):
// janelas de 30 ms a cada 10 ms, 40 bandas entre 125 e 7500 Hz, redução de ruído,
// PCAN e escala logarítmica. Cada 10 ms de áudio (160 amostras a 16 kHz) dá 40 valores.
// O Dart chama estas funções por FFI, numa thread à parte.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern "C" {
#include "tensorflow/lite/experimental/microfrontend/lib/frontend.h"
#include "tensorflow/lite/experimental/microfrontend/lib/frontend_util.h"
}

#define KW_EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))

static const int kSampleRate = 16000;
static const int kFeatures = 40;

struct KwHandle {
  FrontendConfig cfg;
  FrontendState st;
};

// Igual a pymicro-features (src/micro_features.cpp) e ao ESPHome micro_wake_word.
static void kw_fill_config(FrontendConfig* cfg) {
  cfg->window.size_ms = 30;
  cfg->window.step_size_ms = 10;
  cfg->filterbank.num_channels = kFeatures;
  cfg->filterbank.lower_band_limit = 125.0f;
  cfg->filterbank.upper_band_limit = 7500.0f;
  cfg->noise_reduction.smoothing_bits = 10;
  cfg->noise_reduction.even_smoothing = 0.025f;
  cfg->noise_reduction.odd_smoothing = 0.06f;
  cfg->noise_reduction.min_signal_remaining = 0.05f;
  cfg->pcan_gain_control.enable_pcan = 1;
  cfg->pcan_gain_control.strength = 0.95f;
  cfg->pcan_gain_control.offset = 80.0f;
  cfg->pcan_gain_control.gain_bits = 21;
  cfg->log_scale.enable_log = 1;
  cfg->log_scale.scale_shift = 6;
}

KW_EXPORT void* kw_create(void) {
  KwHandle* h = (KwHandle*)calloc(1, sizeof(KwHandle));
  if (!h) return nullptr;
  kw_fill_config(&h->cfg);
  if (!FrontendPopulateState(&h->cfg, &h->st, kSampleRate)) {
    free(h);
    return nullptr;
  }
  return h;
}

KW_EXPORT void kw_reset(void* handle) {
  KwHandle* h = (KwHandle*)handle;
  if (!h) return;
  FrontendFreeStateContents(&h->st);
  FrontendPopulateState(&h->cfg, &h->st, kSampleRate);
}

KW_EXPORT void kw_destroy(void* handle) {
  KwHandle* h = (KwHandle*)handle;
  if (!h) return;
  FrontendFreeStateContents(&h->st);
  free(h);
}

KW_EXPORT int32_t kw_feature_size(void) { return kFeatures; }

// Processa [n] amostras de 16 bits (mono, 16 kHz). Escreve em [out] até [max_frames]
// conjuntos de 40 valores (uint16, como no treino antes da divisão por 25,6).
// Devolve o número de conjuntos escritos.
KW_EXPORT int32_t kw_process(void* handle, const int16_t* samples, int32_t n,
                             uint16_t* out, int32_t max_frames) {
  KwHandle* h = (KwHandle*)handle;
  if (!h || !samples || n <= 0) return 0;
  int32_t frames = 0;
  size_t pos = 0;
  // Entrega 160 amostras de cada vez, exatamente como no treino.
  const size_t step = (size_t)(kSampleRate / 1000) * 10;
  while (pos < (size_t)n) {
    size_t chunk = (size_t)n - pos;
    if (chunk > step) chunk = step;
    size_t read = 0;
    FrontendOutput fo = FrontendProcessSamples(&h->st, samples + pos, chunk, &read);
    if (fo.values && fo.size == (size_t)kFeatures && frames < max_frames) {
      memcpy(out + (size_t)frames * kFeatures, fo.values, sizeof(uint16_t) * kFeatures);
      frames++;
    }
    if (read == 0) break;
    pos += read;
  }
  return frames;
}
