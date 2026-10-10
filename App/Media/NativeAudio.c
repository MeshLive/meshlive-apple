#include "NativeAudio.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct NearbyRing {
    float *samples;
    uint32_t capacity;
    _Atomic uint64_t read_index;
    _Atomic uint64_t write_index;
    _Atomic uint64_t drops;
    _Atomic int enabled;
};
NearbyRing *nearby_ring_create(uint32_t capacity) {
    NearbyRing *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->samples = calloc(capacity, sizeof(float)); r->capacity = capacity;
    if (!r->samples) { free(r); return NULL; } return r;
}
void nearby_ring_destroy(NearbyRing *r) { if (r) { free(r->samples); free(r); } }
uint32_t nearby_ring_write(NearbyRing *r, const float *samples, uint32_t count) {
    if (!atomic_load_explicit(&r->enabled, memory_order_acquire)) return 0;
    uint64_t w = atomic_load_explicit(&r->write_index, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->read_index, memory_order_acquire);
    if (count > r->capacity - (w - rd)) { atomic_fetch_add_explicit(&r->drops, count, memory_order_relaxed); return 0; }
    for (uint32_t i = 0; i < count; i++) r->samples[(w + i) % r->capacity] = samples[i];
    atomic_store_explicit(&r->write_index, w + count, memory_order_release); return count;
}
uint32_t nearby_ring_read(NearbyRing *r, float *samples, uint32_t count) {
    uint64_t rd = atomic_load_explicit(&r->read_index, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->write_index, memory_order_acquire);
    uint32_t n = (uint32_t)(w - rd); if (n > count) n = count;
    for (uint32_t i = 0; i < n; i++) samples[i] = r->samples[(rd + i) % r->capacity];
    atomic_store_explicit(&r->read_index, rd + n, memory_order_release); return n;
}
uint64_t nearby_ring_drops(NearbyRing *r) { return atomic_load_explicit(&r->drops, memory_order_relaxed); }
void nearby_ring_enable(NearbyRing *r, int enabled) { atomic_store_explicit(&r->enabled, enabled, memory_order_release); }

#if __has_include(<opus.h>)
#include <opus.h>
int nearby_opus_available(void) { return 1; }
void *nearby_opus_encoder(int rate, int bitrate, int *error) {
    OpusEncoder *e = opus_encoder_create(rate, 1, OPUS_APPLICATION_VOIP, error);
    if (!e) return NULL;
    *error = opus_encoder_ctl(e, OPUS_SET_BITRATE(bitrate));
    if (!*error) *error = opus_encoder_ctl(e, OPUS_SET_VBR(0));
    if (!*error) *error = opus_encoder_ctl(e, OPUS_SET_COMPLEXITY(5));
    if (*error) { opus_encoder_destroy(e); return NULL; } return e;
}
void *nearby_opus_decoder(int rate, int *error) { return opus_decoder_create(rate, 1, error); }
int nearby_opus_encode(void *e, const float *s, int n, unsigned char *out, int max) { return opus_encode_float(e, s, n, out, max); }
int nearby_opus_decode(void *d, const unsigned char *in, int n, float *s, int max) { return opus_decode_float(d, in, n, s, max, 0); }
int nearby_opus_encoder_reset(void *e) { return opus_encoder_ctl(e, OPUS_RESET_STATE); }
int nearby_opus_decoder_reset(void *d) { return opus_decoder_ctl(d, OPUS_RESET_STATE); }
void nearby_opus_encoder_destroy(void *e) { if (e) opus_encoder_destroy(e); }
void nearby_opus_decoder_destroy(void *d) { if (d) opus_decoder_destroy(d); }
int nearby_opus_encoder_set_fec(void *e, int enabled, int loss) {
    int r = opus_encoder_ctl(e, OPUS_SET_INBAND_FEC(enabled ? 1 : 0));
    if (!r) r = opus_encoder_ctl(e, OPUS_SET_PACKET_LOSS_PERC(enabled ? loss : 0));
    if (!r) r = opus_encoder_ctl(e, OPUS_SET_VBR(enabled ? 1 : 0));
    if (!r) r = opus_encoder_ctl(e, OPUS_SET_VBR_CONSTRAINT(1));
    return r;
}
int nearby_opus_decode_fec(void *d, const unsigned char *in, int n, float *s, int frames) { return opus_decode_float(d, in, n, s, frames, 1); }
int nearby_opus_packet_has_fec(const unsigned char *in, int n) { return opus_packet_has_lbrr(in, n) == 1 ? 1 : 0; }
#else
int nearby_opus_available(void) { return 0; }
void *nearby_opus_encoder(int rate, int bitrate, int *error) { *error = -1; return NULL; }
void *nearby_opus_decoder(int rate, int *error) { *error = -1; return NULL; }
int nearby_opus_encode(void *e, const float *s, int n, unsigned char *out, int max) { return -1; }
int nearby_opus_decode(void *d, const unsigned char *in, int n, float *s, int max) { return -1; }
int nearby_opus_encoder_reset(void *e) { return -1; }
int nearby_opus_decoder_reset(void *d) { return -1; }
void nearby_opus_encoder_destroy(void *e) {}
void nearby_opus_decoder_destroy(void *d) {}
int nearby_opus_encoder_set_fec(void *e, int enabled, int loss) { return -1; }
int nearby_opus_decode_fec(void *d, const unsigned char *in, int n, float *s, int frames) { return -1; }
int nearby_opus_packet_has_fec(const unsigned char *in, int n) { return 0; }
#endif
