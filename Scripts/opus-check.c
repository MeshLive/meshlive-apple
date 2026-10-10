#include "NativeAudio.h"
#include <opus.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    assert(nearby_opus_available());
    int error = 0;
    void *encoder = nearby_opus_encoder(48000, 20000, &error); assert(encoder && !error);
    void *decoder = nearby_opus_decoder(48000, &error); assert(decoder && !error);
    float input[960], output[960]; unsigned char packet[1275];
    double power = 0; int bytes = 0, crossings = 0; float previous = 0;
    for (int frame = 0; frame < 100; frame++) {
        for (int i = 0; i < 960; i++) input[i] = 0.6f * sinf((float)(2 * 3.141592653589793 * 440 * (frame * 960 + i) / 48000));
        int count = nearby_opus_encode(encoder, input, 960, packet, sizeof(packet)); assert(count > 0 && count <= 1275); bytes += count;
        assert(opus_packet_get_nb_samples(packet, count, 48000) == 960);
        assert(nearby_opus_decode(decoder, packet, count, output, 960) == 960);
        for (int i = 0; i < 960; i++) {
            assert(isfinite(output[i]) && fabsf(output[i]) < 1.5);
            if (frame >= 5) { power += output[i] * output[i]; if (previous <= 0 && output[i] > 0) crossings++; }
            previous = output[i];
        }
    }
    double frequency = crossings / 1.9;
    assert(frequency > 435 && frequency < 445); assert(power / (95 * 960) > 0.05);
    assert(bytes == 5000); // 20 kbps CBR over exactly two seconds, before protocol/radio overhead.
    assert(nearby_opus_decode(decoder, NULL, 0, output, 960) == 960); // PLC for one missing packet.
    assert(nearby_opus_encoder_reset(encoder) == 0); assert(nearby_opus_decoder_reset(decoder) == 0);
    assert(nearby_opus_encode(encoder, input, 960, packet, sizeof(packet)) > 0);
    nearby_opus_encoder_destroy(encoder); nearby_opus_decoder_destroy(decoder);
    printf("PASS %s: 100 mono/48k/20ms packets, %d B = 20 kbps, %.1f Hz round-trip; PLC/reset; bridge ASan/UBSan. No device audio claim.\n", opus_get_version_string(), bytes, frequency);
    return 0;
}
