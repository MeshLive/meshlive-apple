package org.nearbyintercom.core;

import java.security.MessageDigest;
import java.util.*;
import java.util.function.Consumer;
import static org.nearbyintercom.core.Wire.*;

/** Confined to the transport's serial handler. Submission failure closes the session to avoid skipped nonces. */
public final class Session {
    public enum State { HANDSHAKE, VERIFICATION, READY, CLOSING, CLOSED }
    public interface Events {
        default void verification(String code, String fingerprint) {}
        default void ready(Profile p) {}
        default void text(long id, String text) {}
        default void acknowledged(long id) {}
        default void cancelled(long id) {}
        default void audio(Media.Packet packet) {}
        default void audioCancelled(long stream) {}
        default void closed(String reason) {}
    }
    public State state = State.HANDSHAKE; public Profile profile; public String peerName = "";
    public byte[] sessionID = new byte[0]; public boolean receivedOrderlyClose;
    public long acknowledgedBytes;
    private final boolean initiator; private final Noise noise; private final Capabilities local;
    private final byte[] expectedPeer; private final Consumer<byte[]> writer; private final Events events;
    private Noise.Cipher sendCipher, receiveCipher;
    private boolean localVerified, remoteVerified; private Capabilities peer;
    private final long created; private long lastReceived, lastSent, closeTime, nextID = 1, lastPeerID;
    private final Map<Long, Pending> pending = new HashMap<>();
    private static class Pending { final long time; final int bytes; Pending(long t, int b) { time = t; bytes = b; } }
    public Session(boolean initiator, byte[] identity, Capabilities local, byte[] token, long now,
                   byte[] expectedPeer, byte[] ephemeral, Consumer<byte[]> writer, Events events) {
        require(token.length == 16, "Invalid host token"); this.initiator = initiator; this.local = local;
        this.expectedPeer = expectedPeer; this.writer = writer; this.events = events; created = lastReceived = lastSent = now;
        noise = new Noise(initiator, identity, concat(utf8("NearbyIntercom/v1"), new byte[]{(byte)local.transport}, token), ephemeral);
    }
    public int pendingCount() { return pending.size(); }
    public void start(long now) { if (initiator && state == State.HANDSHAKE) emit(concat(new byte[]{1}, noise.write(local.encoded())), now); }
    public void receive(byte[] record, long now) {
        if (state == State.CLOSED) return;
        try {
            require(record.length > 0 && record.length <= MAX_RECORD, "Invalid record size"); int type = record[0] & 255;
            if (state == State.HANDSHAKE) {
                int expected = initiator ? 2 : peer == null ? 1 : 3; require(type == expected, "Unexpected handshake record");
                byte[] payload = noise.read(Arrays.copyOfRange(record, 1, record.length));
                if (type == 1 || type == 2) {
                    peer = Capabilities.decode(payload); peerName = peer.name; profile = local.negotiate(peer);
                    if (type == 1) emit(concat(new byte[]{2}, noise.write(local.encoded())), now);
                    else { emit(concat(new byte[]{3}, noise.write(profile.encoded())), now); establish(); }
                } else { require(Arrays.equals(payload, profile.encoded()), "Media selection mismatch"); establish(); }
            } else { require(type == 4, "Unexpected post-handshake record"); encrypted(record, now); }
            lastReceived = now;
        } catch (RuntimeException e) { fail(e.getMessage()); throw e; }
    }
    private void establish() {
        Noise.Cipher[] c = noise.split(expectedPeer); sendCipher = c[0]; receiveCipher = c[1];
        sessionID = Arrays.copyOf(noise.hash, 16); state = State.VERIFICATION;
        String h = hex(Arrays.copyOf(Noise.sha(concat(utf8("NearbyIntercom SAS v1"), noise.hash)), 5)).toUpperCase(Locale.ROOT);
        events.verification(h.substring(0, 5) + " " + h.substring(5), hex(Arrays.copyOf(Noise.sha(noise.remoteIdentity()), 8)).toUpperCase(Locale.ROOT));
    }
    public void verify(long now) {
        require(state == State.VERIFICATION && !localVerified, "Verification is not pending");
        send(1, noise.hash, now); localVerified = true; ready();
    }
    private void ready() { if (localVerified && remoteVerified) { state = State.READY; events.ready(profile); } }
    public long sendText(String text, long now) {
        byte[] b = utf8(text); require(state == State.READY && b.length > 0 && b.length <= MAX_TEXT, "Text must be 1–4096 bytes in a verified session");
        require(pending.size() < 16 && nextID < 0xffffffffL, "Too many pending messages"); long id = nextID++;
        pending.put(id, new Pending(now, b.length)); send(2, new Writer().u32(id).bytes(b).get(), now); return id;
    }
    public void cancel(long id, long now) { if (pending.remove(id) != null) { send(4, new Writer().u32(id).get(), now); events.cancelled(id); } }
    public void audio(Media.Packet p, long now) { Media.Packet.decode(p.encoded(), profile); send(9, p.encoded(), now); }
    public void cancelAudio(long stream, long now) { if (stream > 0) send(12, new Writer().u32(stream).get(), now); }
    public void close(String reason, long now) {
        if (state == State.CLOSED || state == State.CLOSING) return;
        if (sendCipher == null) { fail(reason); return; }
        send(7, prefix(reason, 128), now); state = State.CLOSING; closeTime = now;
    }
    public void tick(long now) {
        if (state == State.CLOSED) return;
        if (state == State.CLOSING) { if (now - closeTime >= 2000) fail("Local close without remote confirmation"); return; }
        if (state == State.HANDSHAKE && now - created > 20000) { fail("Noise handshake timeout"); return; }
        if (state == State.VERIFICATION && now - created > 120000) { fail("Peer verification timeout"); return; }
        if (state == State.READY) {
            if (now - lastReceived > 15000) { fail("Peer keepalive timeout"); return; }
            for (Pending p : pending.values()) if (now - p.time > 10000) { fail("Remote application ACK timeout"); return; }
            if (now - lastSent >= 5000) send(5, new Writer().u64(now - created).get(), now);
        }
    }
    public void fail(String reason) {
        if (state == State.CLOSED) return; state = State.CLOSED; sendCipher = receiveCipher = null; pending.clear(); events.closed(reason);
    }
    private void emit(byte[] r, long now) {
        try { writer.accept(r); lastSent = now; } catch (RuntimeException ex) { fail("Transport submission failed: " + ex.getMessage()); throw ex; }
    }
    private void send(int kind, byte[] payload, long now) {
        require(sendCipher != null && payload.length <= MAX_RECORD - 47, "No secure writer or oversized payload");
        require(state == State.READY || kind == 1 || kind == 7 || kind == 8, "Both peers must verify");
        byte[] header = new Writer().u8(4).u8(1).u8(kind).bytes(sessionID).u64(sendCipher.counter).u32(payload.length).get();
        emit(concat(header, sendCipher.encrypt(payload, concat(noise.hash, header))), now);
    }
    private void encrypted(byte[] record, long now) {
        require(receiveCipher != null && record.length >= 47, "Short encrypted record"); Reader r = new Reader(record); r.u8();
        require(r.u8() == 1, "Unsupported encrypted version"); int kind = r.u8();
        require(kind >= 1 && kind <= 12 && Arrays.equals(r.bytes(16), sessionID), "Unknown message or wrong session");
        require(r.u64() == receiveCipher.counter, "Sequence mismatch or replay"); long size = r.u32();
        require(size <= MAX_RECORD - 47 && r.remaining() == size + 16, "Encrypted length mismatch");
        byte[] payload = receiveCipher.decrypt(r.bytes(r.remaining()), concat(noise.hash, Arrays.copyOf(record, 31)));
        require(state == State.READY || kind == 1 || kind == 7 || kind == 8, "Unverified application data"); Reader p = new Reader(payload);
        switch (kind) {
            case 1:
                require(state == State.VERIFICATION && !remoteVerified && MessageDigest.isEqual(payload, noise.hash), "Invalid peer verification");
                remoteVerified = true; ready(); break;
            case 2:
                long id = p.u32(); require(id > lastPeerID && p.remaining() > 0 && p.remaining() <= MAX_TEXT, "Invalid text ID or size");
                String text = text(p.bytes(p.remaining())); lastPeerID = id; events.text(id, text);
                send(3, new Writer().u32(id).get(), now); break;
            case 3:
                long ack = p.u32(); p.end(); require(ack > 0 && ack < nextID, "Unknown ACK");
                Pending message = pending.remove(ack); if (message != null) { acknowledgedBytes += message.bytes; events.acknowledged(ack); } break;
            case 4:
                long cancel = p.u32(); p.end(); require(cancel > 0, "Invalid cancellation"); events.cancelled(cancel); break;
            case 5: p.u64(); p.end(); send(6, payload, now); break;
            case 6: p.u64(); p.end(); break;
            case 7:
                require(payload.length <= 128, "Invalid close length"); String reason = text(payload);
                send(8, new byte[0], now); receivedOrderlyClose = true; fail("Peer closed: " + reason); break;
            case 8: p.end(); require(state == State.CLOSING, "Unexpected close ACK"); fail("Orderly close acknowledged"); break;
            case 9: events.audio(Media.Packet.decode(payload, profile)); break;
            case 12:
                long stream = p.u32(); p.end(); require(stream > 0, "Invalid audio cancel"); events.audioCancelled(stream); break;
            default: throw new Fault("Android video is not negotiated");
        }
    }
}
