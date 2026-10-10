package org.nearbyintercom.core;

import org.junit.Test;
import org.json.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import static org.junit.Assert.*;
import static org.nearbyintercom.core.Wire.*;

public class InteropTests {
    private static byte[] key(int v) { byte[] b = new byte[32]; Arrays.fill(b, (byte)v); return b; }
    private static void fails(Runnable r) { assertThrows(Fault.class, r::run); }
    private static class Pair {
        final Session a, b; final List<byte[]> aOut = new ArrayList<>(), bOut = new ArrayList<>();
        final List<String> texts = new ArrayList<>(), codes = new ArrayList<>();
        Pair(int transport, int mask, byte[] expected) {
            Capabilities c = new Capabilities(transport, mask, 0, "Fixture"); byte[] token = new byte[16]; Arrays.fill(token, (byte)0xaf);
            a = new Session(true, key(1), c, token, 0, expected, key(3), aOut::add, new Session.Events() {
                public void verification(String code, String fingerprint) { codes.add(code); }
                public void text(long id, String text) { texts.add(text); }
            });
            b = new Session(false, key(2), c, token, 0, null, key(4), bOut::add, new Session.Events() {
                public void verification(String code, String fingerprint) { codes.add(code); }
                public void text(long id, String text) { texts.add(text); }
            });
        }
        void pump() {
            for (int count = 0; !aOut.isEmpty() || !bOut.isEmpty(); count++) {
                require(count < 100, "Test pump bound");
                while (!aOut.isEmpty()) b.receive(aOut.remove(0), 2);
                while (!bOut.isEmpty()) a.receive(bOut.remove(0), 2);
            }
        }
        void handshake() { a.start(0); pump(); }
        void ready() { handshake(); a.verify(1); b.verify(1); pump(); }
    }
    @Test public void swiftGeneratedFixtureIsByteExact() throws Exception {
        JSONObject f = new JSONObject(Files.readString(Path.of("Tests/NearbyV1ExperimentalTests/Fixtures/session-v1.json")));
        Pair p = new Pair(1, 2, null); List<byte[]> generated = new ArrayList<>(); p.a.start(0);
        JSONArray records = f.getJSONArray("records");
        for (int i = 0; i < records.length(); i++) {
            if (i == 3) { p.a.verify(1); p.b.verify(1); }
            if (i == 5) p.a.sendText("Fixture hello", 2);
            JSONObject item = records.getJSONObject(i); byte[] expected = unhex(item.getString("hex"));
            boolean fromA = item.getString("from").equals("initiator"); byte[] actual = (fromA ? p.aOut : p.bOut).remove(0);
            assertArrayEquals("record " + i, expected, actual); generated.add(actual); (fromA ? p.b : p.a).receive(expected, 2);
        }
        assertEquals(f.getString("sessionID"), hex(p.a.sessionID));
        assertEquals(Arrays.asList("EA8E7 E1BD6", "EA8E7 E1BD6"), p.codes);
        assertEquals(Collections.singletonList("Fixture hello"), p.texts);
        assertEquals(13, p.a.acknowledgedBytes); assertEquals(Session.State.READY, p.a.state);
    }
    @Test public void independentNoiseKnownAnswer() {
        byte[] prologue = unhex("50726f6c6f677565313233");
        Noise a = new Noise(true, unhex("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1"), prologue, unhex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a"));
        Noise b = new Noise(false, unhex("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893"), prologue, unhex("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b"));
        String[] payloads = {"4c756477696720766f6e204d69736573", "4d757272617920526f746862617264", "462e20412e20486179656b"};
        String[] ciphertexts = {
            "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573",
            "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b94a6d8798832d5372f220f161d9c2df035528f8982ffe09be9b5c412f8a0db5d21351f20af1370d0bf8ef1a8c59a30e",
            "c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a8589981dfbd651e6ff4724a781cc2aa6158c9fea0d4ec82a286427484c5b8c8123a7a6002b1de9f9775fc97"};
        for (int i = 0; i < 3; i++) {
            byte[] msg = (i == 1 ? b : a).write(unhex(payloads[i])); assertEquals(ciphertexts[i], hex(msg));
            assertArrayEquals(unhex(payloads[i]), (i == 1 ? a : b).read(msg));
        }
        assertEquals("852a28d2146785c54bd8334f4e460c80d7fe4fd0cc5bc0abef2a24a3c4d44d5f", hex(a.hash));
        Noise.Cipher[] ac = a.split(null), bc = b.split(null);
        byte[] encrypted = bc[0].encrypt(unhex("4361726c204d656e676572"), new byte[0]);
        assertEquals("96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df", hex(encrypted));
        assertArrayEquals(unhex("4361726c204d656e676572"), ac[1].decrypt(encrypted, new byte[0]));
    }
    @Test public void fragmentedAndCoalescedStream() {
        byte[] data = concat(frame(utf8("hello")), frame(new byte[32768]), frame(utf8("end"))); Random rand = new Random(73);
        Decoder decoder = new Decoder(); List<byte[]> out = new ArrayList<>();
        for (int offset = 0; offset < data.length;) { int n = Math.min(data.length - offset, 1 + rand.nextInt(83)); out.addAll(decoder.feed(Arrays.copyOfRange(data, offset, offset + n))); offset += n; }
        assertEquals(3, out.size()); assertEquals("hello", text(out.get(0))); assertEquals(32768, out.get(1).length); assertEquals(0, decoder.buffered());
        assertEquals(2, new Decoder().feed(concat(frame(new byte[]{1}), frame(new byte[]{2}))).size());
    }
    @Test public void malformedLengthsAndUTF8() {
        fails(() -> new Decoder().feed(new byte[4])); fails(() -> new Decoder().feed(new Writer().u32(0xffffffffL).get()));
        fails(() -> new Decoder().feed(new byte[65545])); fails(() -> text(new byte[]{(byte)0xc0, (byte)0x80}));
        fails(() -> Capabilities.decode(new byte[]{1,1,4,0,0}));
    }
    @Test public void chunksAtActualATTLimitAndGapRejection() {
        byte[] framed = frame(new byte[777]); Assembler a = new Assembler(); byte[] result = null;
        List<byte[]> chunks = chunks(framed, 0, 20);
        for (byte[] c : chunks) { assertTrue(c.length <= 20); result = a.feed(c); } assertArrayEquals(framed, result);
        fails(() -> a.feed(chunks.get(0))); Assembler gap = new Assembler(); gap.feed(chunks.get(0)); fails(() -> gap.feed(chunks.get(2)));
        fails(() -> chunks(framed, 1, 9));
    }
    @Test public void verificationRequiredAndBidirectionalACK() {
        Pair p = new Pair(2, 3, null); p.handshake(); fails(() -> p.a.sendText("early", 1));
        p.a.verify(1); p.pump(); assertEquals(Session.State.VERIFICATION, p.a.state); p.b.verify(1); p.pump();
        assertEquals(1, p.a.profile.codec); p.a.sendText("alpha", 3); p.b.sendText("βeta", 3);
        assertEquals(1, p.a.pendingCount()); assertEquals(0, p.a.acknowledgedBytes); p.pump();
        assertEquals(5, p.a.acknowledgedBytes); assertEquals(5, p.b.acknowledgedBytes); assertEquals(0, p.a.pendingCount());
    }
    @Test public void tamperReplayAndSequenceGapClose() {
        Pair tamper = new Pair(1, 2, null); tamper.ready(); tamper.a.sendText("secret", 3); byte[] m = tamper.aOut.remove(0); m[m.length-1] ^= 1;
        fails(() -> tamper.b.receive(m, 3)); assertEquals(Session.State.CLOSED, tamper.b.state); assertTrue(tamper.texts.isEmpty());
        Pair replay = new Pair(1, 2, null); replay.ready(); replay.a.sendText("once", 3); byte[] r = replay.aOut.remove(0); replay.b.receive(r, 3);
        fails(() -> replay.b.receive(r, 3)); assertEquals(1, replay.texts.size());
        Pair gap = new Pair(1, 2, null); gap.ready(); gap.a.sendText("lost", 3); gap.a.sendText("later", 3); fails(() -> gap.b.receive(gap.aOut.get(1), 3));
    }
    @Test public void wrongPinnedPeerAndFreshSessionIsolation() {
        Pair p = new Pair(1, 2, key(9)); fails(p::handshake); assertEquals(Session.State.CLOSED, p.a.state);
        Pair old = new Pair(1, 2, null); old.ready(); old.a.sendText("stale", 3);
        Pair fresh = new Pair(2, 2, null); fresh.ready(); fails(() -> fresh.b.receive(old.aOut.get(0), 3)); assertTrue(fresh.texts.isEmpty());
    }
    @Test public void negotiationAndKeepaliveTimeouts() {
        fails(() -> new Capabilities(1,1,0,"a").negotiate(new Capabilities(1,2,0,"b")));
        fails(() -> new Capabilities(1,2,0,"a").negotiate(new Capabilities(2,2,0,"b")));
        Pair p = new Pair(1,2,null); p.ready(); p.a.sendText("pending", 3); p.a.tick(10004); assertEquals(Session.State.CLOSED,p.a.state);
        Pair q = new Pair(1,2,null); q.ready(); q.a.tick(5002); assertEquals(1,q.aOut.size()); q.pump(); q.b.tick(16003); assertEquals(Session.State.CLOSED,q.b.state);
    }
    @Test public void partialWritesBackpressureBoundsAndCancellation() throws Exception {
        OrderedWriter q = new OrderedWriter(); q.enqueue(Arrays.asList(utf8("abc"),utf8("defg")),10);
        q.consume(1); assertEquals("bc",text(q.peek())); q.consume(0); assertEquals(6,q.bytes()); assertEquals(20,q.age(30));
        q.consume(2); assertEquals("defg",text(q.peek())); q.consume(4); assertNull(q.peek()); assertEquals(7,q.submittedBytes);
        fails(() -> q.enqueue(Collections.singletonList(new byte[131073]),30)); q.cancel(); fails(() -> q.enqueue(Collections.singletonList(new byte[]{1}),40));
        OrderedWriter blocked = new OrderedWriter(); ExecutorService worker = Executors.newSingleThreadExecutor();
        Future<byte[]> waiting = worker.submit(blocked::await); blocked.cancel(); assertNull(waiting.get(1,TimeUnit.SECONDS)); worker.shutdownNow();
    }
    @Test public void orderlyCloseCancellationAndNonceLimits() {
        Pair p = new Pair(1,2,null); p.ready(); long id=p.a.sendText("queued",3); p.a.cancel(id,4); assertEquals(0,p.a.pendingCount()); p.pump();
        p.a.close("Stop",5); p.pump(); assertEquals(Session.State.CLOSED,p.a.state); assertTrue(p.b.receivedOrderlyClose);
        Noise.Cipher c = new Noise.Cipher(key(5)); c.counter=1_000_000_000L; fails(() -> c.encrypt(new byte[0],new byte[0]));
    }
    @Test public void audioFinalJitterLimitsAndInterruption() {
        Profile p=new Profile(2,false); Media.Jitter j=new Media.Jitter(p.frames);
        for(int i=0;i<12;i++) j.push(Media.Packet.decode(new Media.Packet(1,i*160L,i==0?2:0,160,new byte[320]).encoded(),p),i*20L);
        assertTrue(j.buffered()<=10); assertTrue(j.overflows>0); assertNotNull(j.pop(300));
        j.cancel(1); assertFalse(j.active); j.push(new Media.Packet(2,0,2,160,new byte[320]),400);
        j.pop(460); j.pop(480); assertTrue(j.underruns>0); j.push(new Media.Packet(2,160,1,0,new byte[0]),500); assertFalse(j.active);
        fails(() -> Media.Packet.decode(new Media.Packet(3,1,2,160,new byte[320]).encoded(),p));
        fails(() -> Media.Packet.decode(new Media.Packet(3,0,2,159,new byte[320]).encoded(),p));
        fails(() -> j.push(new Media.Packet(1,0,2,160,new byte[320]),600));
    }
}
