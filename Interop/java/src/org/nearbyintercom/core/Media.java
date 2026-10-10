package org.nearbyintercom.core;

import java.util.*;
import static org.nearbyintercom.core.Wire.*;

public final class Media {
    public static class Packet {
        public final long stream, timestamp; public final int flags, valid; public final byte[] payload;
        public Packet(long stream, long timestamp, int flags, int valid, byte[] payload) {
            this.stream = stream; this.timestamp = timestamp; this.flags = flags; this.valid = valid; this.payload = payload;
        }
        public boolean last() { return (flags & 1) != 0; }
        public byte[] encoded() { return new Writer().u32(stream).u64(timestamp).u8(flags).u16(valid).bytes(payload).get(); }
        public static Packet decode(byte[] b, Profile profile) {
            require(profile != null, "Audio not negotiated"); Reader r = new Reader(b); long s = r.u32(), t = r.u64(); int flags = r.u8(), n = r.u16();
            require(s > 0 && t >= 0 && t <= Long.MAX_VALUE - profile.frames && t % profile.frames == 0 && (flags & ~3) == 0, "Invalid audio stream, timestamp or flags");
            boolean last = (flags & 1) != 0; require(n <= profile.frames && (last || n == profile.frames) && (n > 0 || last), "Invalid sample count");
            byte[] p = r.bytes(r.remaining());
            if (n == 0) require(p.length == 0, "Empty final has payload");
            else if (profile.codec == 1) require(p.length > 0 && p.length <= 1275, "Invalid Opus packet");
            else require(p.length == profile.frames * 2, "Invalid PCM diagnostic length");
            return new Packet(s, t, flags, n, p);
        }
    }
    /** 60 ms target, 200 ms cap, monotonic stream IDs; late final packets still end playout. */
    public static class Jitter {
        private final int frames; private final TreeMap<Long, Packet> packets = new TreeMap<>();
        private long stream, lastStream, next, finalTime = -1, lastTimestamp = -1; private boolean started; private long firstArrival;
        public long underruns, overflows, late; public boolean active;
        public Jitter(int frames) { this.frames = frames; }
        public int buffered() { return packets.size(); }
        public void push(Packet p, long now) {
            if (p.stream != stream) {
                require(p.stream > lastStream && p.timestamp == 0 && (p.flags & 2) != 0, "New audio stream needs discontinuity at zero");
                packets.clear(); stream = lastStream = p.stream; next = 0; finalTime = -1; lastTimestamp = -1;
                started = false; active = true; firstArrival = now;
            } else require((p.flags & 2) == 0, "Unexpected audio discontinuity");
            require(active && p.timestamp > lastTimestamp, "Closed stream or audio replay"); lastTimestamp = p.timestamp;
            if (p.last()) finalTime = p.timestamp;
            if (p.timestamp < next) { late++; if (p.last()) clear(); return; }
            require(!packets.containsKey(p.timestamp), "Duplicate audio timestamp"); packets.put(p.timestamp, p);
            if (packets.size() > 10 || packets.lastKey() - next >= frames * 10L) {
                packets.pollFirstEntry(); next = packets.isEmpty() ? p.timestamp : packets.firstKey(); overflows++;
            }
        }
        public Packet pop(long now) {
            if (!active) return null;
            if (!started) { if (now - firstArrival < 60) return null; started = true; }
            Packet p = packets.remove(next); long timestamp = next; next += frames;
            if (p == null) { underruns++; p = new Packet(stream, timestamp, 0, frames, null); }
            if (p.last() || (finalTime >= 0 && timestamp >= finalTime)) clear(); return p;
        }
        public void cancel(long id) { if (id >= stream) { lastStream = Math.max(lastStream, id); clear(); } }
        public void clear() { packets.clear(); active = false; started = false; }
    }
}
