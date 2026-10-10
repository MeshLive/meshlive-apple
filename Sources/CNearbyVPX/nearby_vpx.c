#include "nearby_vpx.h"
#include <stdlib.h>
#include <string.h>

#if __has_include(<vpx/vp8cx.h>)
#include <vpx/vp8cx.h>
#include <vpx/vp8dx.h>
#include <vpx/vpx_encoder.h>
#include <vpx/vpx_decoder.h>

struct NearbyVP9Encoder { vpx_codec_ctx_t ctx; vpx_codec_enc_cfg_t cfg; vpx_image_t image; int width, height; };
struct NearbyVP9Decoder { vpx_codec_ctx_t ctx; };

int nearby_vpx_available(void) { return 1; }

NearbyVP9Encoder *nearby_vp9_encoder_create(int width, int height, int fps, int bitrate_kbps, int threads, int speed, int *error) {
    *error = 0;
    if (width < 16 || height < 16 || width > 4096 || height > 4096 || (width & 1) || (height & 1) ||
        fps < 1 || fps > 120 || bitrate_kbps < 10) { *error = -1; return NULL; }
    NearbyVP9Encoder *e = calloc(1, sizeof(*e));
    if (!e) { *error = -1; return NULL; }
    vpx_codec_iface_t *iface = vpx_codec_vp9_cx();
    if (vpx_codec_enc_config_default(iface, &e->cfg, 0)) { free(e); *error = -2; return NULL; }
    e->cfg.g_w = (unsigned)width; e->cfg.g_h = (unsigned)height;
    e->cfg.g_timebase.num = 1; e->cfg.g_timebase.den = 1000000;
    e->cfg.g_threads = threads > 0 ? (unsigned)threads : 1;
    e->cfg.g_lag_in_frames = 0;
    e->cfg.g_error_resilient = 0;
    e->cfg.g_pass = VPX_RC_ONE_PASS;
    e->cfg.rc_end_usage = VPX_CBR;
    e->cfg.rc_target_bitrate = (unsigned)bitrate_kbps;
    e->cfg.rc_min_quantizer = 4; e->cfg.rc_max_quantizer = 56;
    e->cfg.rc_undershoot_pct = 50; e->cfg.rc_overshoot_pct = 50;
    e->cfg.rc_buf_sz = 1000; e->cfg.rc_buf_initial_sz = 500; e->cfg.rc_buf_optimal_sz = 600;
    e->cfg.rc_dropframe_thresh = 0; /* no encoder frame drops: latency over loss (Android default) */
    e->cfg.kf_mode = VPX_KF_AUTO; e->cfg.kf_min_dist = 0; e->cfg.kf_max_dist = (unsigned)(fps * 60); /* keyframes on demand */
    if (vpx_codec_enc_init(&e->ctx, iface, &e->cfg, 0)) { free(e); *error = -3; return NULL; }
    vpx_codec_control(&e->ctx, VP8E_SET_CPUUSED, speed);
    vpx_codec_control(&e->ctx, VP9E_SET_AQ_MODE, 3);
    vpx_codec_control(&e->ctx, VP9E_SET_ROW_MT, 1);
    vpx_codec_control(&e->ctx, VP9E_SET_TILE_COLUMNS, width >= 640 ? 1 : 0);
    vpx_codec_control(&e->ctx, VP8E_SET_MAX_INTRA_BITRATE_PCT, 300); /* bound keyframe bursts on Bluetooth */
    vpx_codec_control(&e->ctx, VP9E_SET_NOISE_SENSITIVITY, 0);
    vpx_codec_control(&e->ctx, VP8E_SET_STATIC_THRESHOLD, 1);
    e->width = width; e->height = height;
    return e;
}

int nearby_vp9_encode(NearbyVP9Encoder *e, const NearbyI420Frame *f, int64_t pts_us, int duration_us,
                      int force_keyframe, uint8_t *out, int out_capacity, int *keyframe) {
    *keyframe = 0;
    if (!e || !f || f->width != e->width || f->height != e->height || !f->y || !f->u || !f->v) return -1;
    vpx_img_wrap(&e->image, VPX_IMG_FMT_I420, (unsigned)e->width, (unsigned)e->height, 1, (unsigned char *)f->y);
    e->image.planes[VPX_PLANE_Y] = (unsigned char *)f->y; e->image.stride[VPX_PLANE_Y] = f->y_stride;
    e->image.planes[VPX_PLANE_U] = (unsigned char *)f->u; e->image.stride[VPX_PLANE_U] = f->u_stride;
    e->image.planes[VPX_PLANE_V] = (unsigned char *)f->v; e->image.stride[VPX_PLANE_V] = f->v_stride;
    if (vpx_codec_encode(&e->ctx, &e->image, pts_us, (unsigned long)(duration_us > 0 ? duration_us : 1),
                         force_keyframe ? VPX_EFLAG_FORCE_KF : 0, VPX_DL_REALTIME)) return -1;
    int written = 0;
    vpx_codec_iter_t iter = NULL;
    const vpx_codec_cx_pkt_t *pkt;
    while ((pkt = vpx_codec_get_cx_data(&e->ctx, &iter)) != NULL) {
        if (pkt->kind != VPX_CODEC_CX_FRAME_PKT) continue;
        if ((int)pkt->data.frame.sz > out_capacity - written) return -2;
        memcpy(out + written, pkt->data.frame.buf, pkt->data.frame.sz);
        written += (int)pkt->data.frame.sz;
        if (pkt->data.frame.flags & VPX_FRAME_IS_KEY) *keyframe = 1;
    }
    return written;
}

int nearby_vp9_encoder_set_bitrate(NearbyVP9Encoder *e, int kbps) {
    if (!e || kbps < 10) return -1;
    e->cfg.rc_target_bitrate = (unsigned)kbps;
    return vpx_codec_enc_config_set(&e->ctx, &e->cfg) ? -1 : 0;
}
const char *nearby_vp9_encoder_error(NearbyVP9Encoder *e) { return e ? vpx_codec_error(&e->ctx) : "no encoder"; }
void nearby_vp9_encoder_destroy(NearbyVP9Encoder *e) { if (e) { vpx_codec_destroy(&e->ctx); free(e); } }

NearbyVP9Decoder *nearby_vp9_decoder_create(int threads, int *error) {
    *error = 0;
    NearbyVP9Decoder *d = calloc(1, sizeof(*d));
    if (!d) { *error = -1; return NULL; }
    vpx_codec_dec_cfg_t cfg = { (unsigned)(threads > 0 ? threads : 1), 0, 0 };
    if (vpx_codec_dec_init(&d->ctx, vpx_codec_vp9_dx(), &cfg, 0)) { free(d); *error = -2; return NULL; }
    return d;
}

int nearby_vp9_decode(NearbyVP9Decoder *d, const uint8_t *data, int size, NearbyI420Frame *f) {
    if (!d || !data || size <= 0) return -1;
    if (vpx_codec_decode(&d->ctx, data, (unsigned)size, NULL, 0)) return -1;
    vpx_codec_iter_t iter = NULL;
    vpx_image_t *img = NULL, *next;
    while ((next = vpx_codec_get_frame(&d->ctx, &iter)) != NULL) img = next;
    if (!img) return 0;
    if (img->fmt != VPX_IMG_FMT_I420 || img->bit_depth != 8) return -1;
    f->width = (int)img->d_w; f->height = (int)img->d_h;
    f->y = img->planes[VPX_PLANE_Y]; f->u = img->planes[VPX_PLANE_U]; f->v = img->planes[VPX_PLANE_V];
    f->y_stride = img->stride[VPX_PLANE_Y]; f->u_stride = img->stride[VPX_PLANE_U]; f->v_stride = img->stride[VPX_PLANE_V];
    return 1;
}
const char *nearby_vp9_decoder_error(NearbyVP9Decoder *d) { return d ? vpx_codec_error(&d->ctx) : "no decoder"; }
void nearby_vp9_decoder_destroy(NearbyVP9Decoder *d) { if (d) { vpx_codec_destroy(&d->ctx); free(d); } }

#else
int nearby_vpx_available(void) { return 0; }
NearbyVP9Encoder *nearby_vp9_encoder_create(int w, int h, int fps, int kbps, int t, int s, int *error) { *error = -100; return NULL; }
int nearby_vp9_encode(NearbyVP9Encoder *e, const NearbyI420Frame *f, int64_t p, int d, int k, uint8_t *o, int c, int *kf) { *kf = 0; return -1; }
int nearby_vp9_encoder_set_bitrate(NearbyVP9Encoder *e, int kbps) { return -1; }
const char *nearby_vp9_encoder_error(NearbyVP9Encoder *e) { return "libvpx is not linked (run Scripts/prepare-libvpx.sh)"; }
void nearby_vp9_encoder_destroy(NearbyVP9Encoder *e) {}
NearbyVP9Decoder *nearby_vp9_decoder_create(int t, int *error) { *error = -100; return NULL; }
int nearby_vp9_decode(NearbyVP9Decoder *d, const uint8_t *data, int size, NearbyI420Frame *f) { return -1; }
const char *nearby_vp9_decoder_error(NearbyVP9Decoder *d) { return "libvpx is not linked (run Scripts/prepare-libvpx.sh)"; }
void nearby_vp9_decoder_destroy(NearbyVP9Decoder *d) {}
#endif
