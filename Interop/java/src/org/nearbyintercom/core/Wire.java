package org.nearbyintercom.core;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Platform-independent implementation of PROTOCOL.md. All integers on the wire are big endian. */
public final class Wire {
    public static final int MAX_RECORD = 32768, MAX_TEXT = 4096;
    public static final UUID SERVICE = UUID.fromString("7D2C9B68-19E6-4F03-8B41-82AE51F26790");
    public static final UUID INFO = UUID.fromString("7D2C9B68-19E6-4F03-8B41-82AE51F26791");
    public static final UUID WRITE = UUID.fromString("7D2C9B68-19E6-4F03-8B41-82AE51F26792");
    public static final UUID NOTIFY = UUID.fromString("7D2C9B68-19E6-4F03-8B41-82AE51F26793");
    public static final class Fault extends RuntimeException { public Fault(String s) { super(s); } }
    public static void require(boolean condition, String reason) { if (!condition) throw new Fault(reason); }
    public static byte[] concat(byte[]... items) {
        ByteArrayOutputStream b = new ByteArrayOutputStream(); for (byte[] x : items) b.write(x, 0, x.length); return b.toByteArray();
    }
    public static byte[] utf8(String s) { return s.getBytes(StandardCharsets.UTF_8); }
    public static String text(byte[] b) {
        try { return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(b)).toString(); }
        catch (Exception e) { throw new Fault("Invalid UTF-8"); }
    }
    public static byte[] prefix(String s, int limit) {
        Writer w = new Writer();
        for (int offset = 0; offset < s.length();) {
            int cp = s.codePointAt(offset); byte[] b = utf8(new String(Character.toChars(cp)));
            if (w.size() + b.length > limit) break; w.bytes(b); offset += Character.charCount(cp);
        }
        return w.get();
    }
    public static String hex(byte[] b) {
        StringBuilder s = new StringBuilder(); for (byte v : b) s.append(String.format(Locale.ROOT, "%02x", v & 255)); return s.toString();
    }
    public static byte[] unhex(String s) {
        require(s.length() % 2 == 0, "Odd hex"); byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16); return b;
    }
    public static class Writer {
        private final ByteArrayOutputStream b = new ByteArrayOutputStream();
        public Writer u8(int v) { b.write(v); return this; }
        public Writer u16(int v) { return u8(v >>> 8).u8(v); }
        public Writer u32(long v) { for (int shift = 24; shift >= 0; shift -= 8) u8((int)(v >>> shift)); return this; }
        public Writer u64(long v) { for (int shift = 56; shift >= 0; shift -= 8) u8((int)(v >>> shift)); return this; }
        public Writer bytes(byte[] v) { b.write(v, 0, v.length); return this; }
        public byte[] get() { return b.toByteArray(); }
        public int size() { return b.size(); }
    }
    public static class Reader {
        private final byte[] b; private int offset;
        public Reader(byte[] b) { this.b = b; }
        public int remaining() { return b.length - offset; }
        public int u8() { require(remaining() > 0, "Truncated field"); return b[offset++] & 255; }
        public int u16() { return (u8() << 8) | u8(); }
        public long u32() { long v = 0; for (int i = 0; i < 4; i++) v = (v << 8) | u8(); return v; }
        public long u64() { long v = 0; for (int i = 0; i < 8; i++) v = (v << 8) | u8(); return v; }
        public byte[] bytes(int n) {
            require(n >= 0 && n <= remaining(), "Truncated field"); byte[] r = Arrays.copyOfRange(b, offset, offset + n); offset += n; return r;
        }
        public void end() { require(remaining() == 0, "Trailing bytes"); }
    }
    public static byte[] frame(byte[] r) {
        require(r.length > 0 && r.length <= MAX_RECORD, "Record length out of range"); return new Writer().u32(r.length).bytes(r).get();
    }
    public static class Decoder {
        private byte[] buffer = new byte[0];
        public List<byte[]> feed(byte[] in) {
            require(in.length <= MAX_RECORD + 4 && buffer.length + in.length <= 2 * (MAX_RECORD + 4), "Receive buffer exhausted");
            buffer = concat(buffer, in); List<byte[]> records = new ArrayList<>(); int offset = 0;
            while (buffer.length - offset >= 4) {
                long n = new Reader(Arrays.copyOfRange(buffer, offset, offset + 4)).u32();
                require(n > 0 && n <= MAX_RECORD, "Invalid record length");
                if (buffer.length - offset < n + 4) break;
                records.add(Arrays.copyOfRange(buffer, offset + 4, offset + 4 + (int)n)); offset += 4 + (int)n;
            }
            buffer = Arrays.copyOfRange(buffer, offset, buffer.length); return records;
        }
        public int buffered() { return buffer.length; }
    }
    public static List<byte[]> chunks(byte[] frame, long id, int max) {
        require(max > 9 && max <= 65535 && frame.length >= 5 && frame.length <= MAX_RECORD + 4, "Invalid GATT limits");
        require(id >= 0 && id < 0xffffffffL, "GATT counter exhausted");
        List<byte[]> out = new ArrayList<>();
        for (int offset = 0; offset < frame.length; offset += max - 9)
            out.add(new Writer().u8(1).u32(id).u16(offset).u16(frame.length)
                .bytes(Arrays.copyOfRange(frame, offset, Math.min(frame.length, offset + max - 9))).get());
        return out;
    }
    public static class Assembler {
        private long expected = 0, id = -1; private int total;
        private final ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        public byte[] feed(byte[] b) {
            Reader r = new Reader(b); require(r.u8() == 1, "Unknown BLE chunk version");
            long incoming = r.u32(); int offset = r.u16(), size = r.u16();
            require(size >= 5 && size <= MAX_RECORD + 4 && r.remaining() > 0, "Invalid BLE chunk size");
            if (id == -1) { require(offset == 0 && incoming == expected, "BLE replay or gap"); id = incoming; total = size; }
            require(id == incoming && total == size && offset == buffer.size() && offset + r.remaining() <= total, "Out of order BLE fragment");
            byte[] p = r.bytes(r.remaining()); buffer.write(p, 0, p.length);
            if (buffer.size() != total) return null;
            require(expected < 0xffffffffL, "BLE counter exhausted"); expected++; id = -1;
            byte[] result = buffer.toByteArray(); buffer.reset(); return result;
        }
    }
    public static class Capabilities {
        public final int transport, audioMask, videoMask; public final String name;
        public Capabilities(int transport, int audioMask, int videoMask, String name) {
            require(transport == 1 || transport == 2, "Unsupported transport");
            require(audioMask > 0 && (audioMask & ~3) == 0 && (videoMask & ~1) == 0, "Invalid codecs");
            this.transport = transport; this.audioMask = audioMask; this.videoMask = videoMask; this.name = name;
        }
        public byte[] encoded() { byte[] n = prefix(name, 48); return new Writer().u8(1).u8(transport).u8(audioMask).u8(videoMask).u8(n.length).bytes(n).get(); }
        public static Capabilities decode(byte[] b) {
            Reader r = new Reader(b); require(r.u8() == 1, "Unsupported protocol version");
            int t = r.u8(), a = r.u8(), v = r.u8(), n = r.u8(); require(n <= 48, "Name too long");
            Capabilities c = new Capabilities(t, a, v, text(r.bytes(n))); r.end(); return c;
        }
        public Profile negotiate(Capabilities c) {
            require(transport == c.transport, "Selected transports differ"); int common = audioMask & c.audioMask;
            if ((common & 1) != 0) return new Profile(1, (videoMask & c.videoMask) != 0);
            require((common & 2) != 0, "No shared audio codec"); return new Profile(2, false);
        }
    }
    public static class Profile {
        public final int codec, rate, frames; public final boolean video;
        public Profile(int codec, boolean video) {
            require(codec == 1 || codec == 2, "Unsupported audio codec"); this.codec = codec; this.video = video;
            rate = codec == 1 ? 48000 : 8000; frames = rate / 50;
        }
        public byte[] encoded() { return new Writer().u8(codec).u32(rate).u8(1).u16(20).u32(codec == 1 ? 20000 : 128000).u8(video ? 1 : 0).get(); }
    }
}
