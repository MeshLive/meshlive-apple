#ifndef NEARBY_NATIVE_AUDIO_H
#define NEARBY_NATIVE_AUDIO_H
#include <stdint.h>
typedef struct NearbyRing NearbyRing;
NearbyRing *nearby_ring_create(uint32_t capacity);
void nearby_ring_destroy(NearbyRing *ring);
uint32_t nearby_ring_write(NearbyRing *ring, const float *samples, uint32_t count);
uint32_t nearby_ring_read(NearbyRing *ring, float *samples, uint32_t count);
uint64_t nearby_ring_drops(NearbyRing *ring);
void nearby_ring_enable(NearbyRing *ring, int enabled);
int nearby_opus_available(void);
void *nearby_opus_encoder(int rate, int bitrate, int *error);
void *nearby_opus_decoder(int rate, int *error);
int nearby_opus_encode(void *encoder, const float *samples, int frames, unsigned char *output, int maximum);
int nearby_opus_decode(void *decoder, const unsigned char *input, int length, float *samples, int frames);
int nearby_opus_encoder_reset(void *encoder);
int nearby_opus_decoder_reset(void *decoder);
void nearby_opus_encoder_destroy(void *encoder);
void nearby_opus_decoder_destroy(void *decoder);
/* Experimental call FEC (Android test_call_native_opus): in-band FEC with an expected-loss hint, constrained VBR. */
int nearby_opus_encoder_set_fec(void *encoder, int enabled, int loss_percent);
/* The frame lost just before `input`, from its in-band FEC data (libopus PLC when it carries none). */
int nearby_opus_decode_fec(void *decoder, const unsigned char *input, int length, float *samples, int frames);
int nearby_opus_packet_has_fec(const unsigned char *input, int length);
#endif
