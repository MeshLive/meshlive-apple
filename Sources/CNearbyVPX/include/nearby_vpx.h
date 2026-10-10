#ifndef NEARBY_VPX_H
#define NEARBY_VPX_H
#include <stdint.h>

/* Small, bounds-checked libvpx VP9 bridge (encoder + decoder). All sizes are bytes or pixels. */
typedef struct NearbyVP9Encoder NearbyVP9Encoder;
typedef struct NearbyVP9Decoder NearbyVP9Decoder;

typedef struct {
    int width, height;
    const uint8_t *y, *u, *v;
    int y_stride, u_stride, v_stride;
} NearbyI420Frame;

/* Real-time CBR VP9 profile 0 (8-bit 4:2:0), no lag, cyclic-refresh AQ, keyframes on demand. */
NearbyVP9Encoder *nearby_vp9_encoder_create(int width, int height, int fps, int bitrate_kbps, int threads, int speed, int *error);
/* Encodes one I420 frame at pts (microseconds). Returns bytes written to out (0 = no output), -1 on error,
   -2 if out_capacity is too small. *keyframe is set to 1 for a keyframe. */
int nearby_vp9_encode(NearbyVP9Encoder *encoder, const NearbyI420Frame *frame, int64_t pts_us, int duration_us,
                      int force_keyframe, uint8_t *out, int out_capacity, int *keyframe);
int nearby_vp9_encoder_set_bitrate(NearbyVP9Encoder *encoder, int bitrate_kbps);
const char *nearby_vp9_encoder_error(NearbyVP9Encoder *encoder);
void nearby_vp9_encoder_destroy(NearbyVP9Encoder *encoder);

NearbyVP9Decoder *nearby_vp9_decoder_create(int threads, int *error);
/* Decodes one access unit (frame or superframe). Returns 1 when *frame holds a picture valid until
   the next call, 0 when no picture is shown, -1 on a corrupt/unsupported stream. 8-bit I420 output only. */
int nearby_vp9_decode(NearbyVP9Decoder *decoder, const uint8_t *data, int size, NearbyI420Frame *frame);
const char *nearby_vp9_decoder_error(NearbyVP9Decoder *decoder);
void nearby_vp9_decoder_destroy(NearbyVP9Decoder *decoder);
int nearby_vpx_available(void);
#endif
