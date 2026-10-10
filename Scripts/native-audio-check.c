#include "NativeAudio.h"
#include <assert.h>
#include <stdio.h>
#include <stdatomic.h>
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio counters must be lock-free on supported targets");
int main(void) {
    NearbyRing *r = nearby_ring_create(8); assert(r);
    float input[10], output[8]; for (int i = 0; i < 10; i++) input[i] = (float)i;
    assert(nearby_ring_write(r, input, 3) == 0); // default inactive
    nearby_ring_enable(r, 1);
    assert(nearby_ring_write(r, input, 5) == 5);
    assert(nearby_ring_read(r, output, 3) == 3); for (int i = 0; i < 3; i++) assert(output[i] == i);
    assert(nearby_ring_write(r, input + 5, 5) == 5); // wrap around
    assert(nearby_ring_write(r, input, 2) == 0); assert(nearby_ring_drops(r) == 2);
    assert(nearby_ring_read(r, output, 8) == 7); for (int i = 0; i < 7; i++) assert(output[i] == i + 3);
    assert(nearby_ring_read(r, output, 1) == 0);
    nearby_ring_enable(r, 0); assert(nearby_ring_write(r, input, 8) == 0);
    nearby_ring_destroy(r); assert(nearby_opus_available() == 0);
    puts("PASS: capture ring wrap, overflow, disabled capture and unavailable Opus; ASan/UBSan enabled");
    return 0;
}
