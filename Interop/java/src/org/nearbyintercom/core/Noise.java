package org.nearbyintercom.core;

import java.security.*;
import java.util.*;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.bouncycastle.crypto.modes.ChaCha20Poly1305;
import org.bouncycastle.crypto.params.AEADParameters;
import org.bouncycastle.crypto.params.KeyParameter;
import org.bouncycastle.math.ec.rfc7748.X25519;
import static org.nearbyintercom.core.Wire.*;

/** Noise XX revision 34. Primitives are Bouncy Castle; pattern is checked against independent Noise vectors. */
public final class Noise {
    private final boolean initiator; private final byte[] s, e;
    private byte[] re, rs, ck; public byte[] hash;
    private Cipher cipher = new Cipher(null); private int step;
    public static byte[] randomKey() { byte[] b = new byte[32]; new SecureRandom().nextBytes(b); return b; }
    public static byte[] sha(byte[] b) {
        try { return MessageDigest.getInstance("SHA-256").digest(b); } catch (Exception ex) { throw new Fault("SHA-256 unavailable"); }
    }
    private static byte[] hmac(byte[] key, byte[] b) {
        try { Mac m = Mac.getInstance("HmacSHA256"); m.init(new SecretKeySpec(key, "HmacSHA256")); return m.doFinal(b); }
        catch (Exception ex) { throw new Fault("HMAC unavailable"); }
    }
    private static byte[][] hkdf(byte[] ck, byte[] in) {
        byte[] temp = hmac(ck, in), first = hmac(temp, new byte[]{1}); return new byte[][]{first, hmac(temp, concat(first, new byte[]{2}))};
    }
    public Noise(boolean initiator, byte[] identity, byte[] prologue, byte[] ephemeral) {
        require(identity.length == 32, "Invalid identity key"); this.initiator = initiator; s = identity.clone(); e = ephemeral == null ? randomKey() : ephemeral.clone();
        require(e.length == 32, "Invalid ephemeral key"); byte[] name = utf8("Noise_XX_25519_ChaChaPoly_SHA256");
        hash = name.length <= 32 ? Arrays.copyOf(name, 32) : sha(name); ck = hash.clone(); mixHash(prologue);
    }
    private void mixHash(byte[] b) { hash = sha(concat(hash, b)); }
    private String[] pattern() { return step == 0 ? new String[]{"e"} : step == 1 ? new String[]{"e", "ee", "s", "es"} : new String[]{"s", "se"}; }
    private static byte[] publicKey(byte[] privateKey) { byte[] b = new byte[32]; X25519.generatePublicKey(privateKey, 0, b, 0); return b; }
    private void dh(String token) {
        byte[] secret, pub;
        if (token.equals("ee")) { secret = e; pub = re; }
        else if (token.equals("es")) { secret = initiator ? e : s; pub = initiator ? rs : re; }
        else { secret = initiator ? s : e; pub = initiator ? re : rs; }
        require(pub != null, "Missing Noise public key"); byte[] shared = new byte[32];
        require(X25519.calculateAgreement(secret, 0, pub, 0, shared, 0), "Invalid X25519 peer");
        byte[][] keys = hkdf(ck, shared); Arrays.fill(shared, (byte)0); ck = keys[0]; cipher = new Cipher(keys[1]);
    }
    private byte[] encryptHash(byte[] b) { byte[] out = cipher.encrypt(b, hash); mixHash(out); return out; }
    private byte[] decryptHash(byte[] b) { byte[] out = cipher.decrypt(b, hash); mixHash(b); return out; }
    public byte[] write(byte[] payload) {
        require(step < 3 && ((step == 1) != initiator) && payload.length <= 256, "Noise write out of order"); Writer w = new Writer();
        for (String t : pattern()) {
            if (t.equals("e")) { byte[] p = publicKey(e); w.bytes(p); mixHash(p); }
            else if (t.equals("s")) w.bytes(encryptHash(publicKey(s))); else dh(t);
        }
        w.bytes(encryptHash(payload)); step++; return w.get();
    }
    public byte[] read(byte[] message) {
        require(step < 3 && ((step == 1) == initiator) && message.length <= 512, "Noise read out of order"); Reader r = new Reader(message);
        for (String t : pattern()) {
            if (t.equals("e")) { re = r.bytes(32); mixHash(re); }
            else if (t.equals("s")) rs = decryptHash(r.bytes(cipher.key == null ? 32 : 48)); else dh(t);
        }
        byte[] payload = decryptHash(r.bytes(r.remaining())); require(payload.length <= 256, "Noise payload too large"); step++; return payload;
    }
    public Cipher[] split(byte[] expectedPeer) {
        require(step == 3 && rs != null, "Incomplete Noise handshake");
        require(expectedPeer == null || MessageDigest.isEqual(expectedPeer, rs), "Wrong peer identity");
        byte[][] keys = hkdf(ck, new byte[0]); Arrays.fill(e, (byte)0); Arrays.fill(s, (byte)0);
        return initiator ? new Cipher[]{new Cipher(keys[0]), new Cipher(keys[1])} : new Cipher[]{new Cipher(keys[1]), new Cipher(keys[0])};
    }
    public byte[] remoteIdentity() { return rs.clone(); }
    public static class Cipher {
        private final byte[] key; public long counter;
        public Cipher(byte[] key) { this.key = key == null ? null : key.clone(); }
        private byte[] crypt(boolean encrypt, byte[] b, byte[] ad) {
            if (key == null) return b.clone(); require(counter < 1_000_000_000L, "Session nonce limit; reconnect");
            require(encrypt || b.length >= 16, "Short authentication tag"); byte[] nonce = new byte[12];
            for (int i = 0; i < 8; i++) nonce[4 + i] = (byte)(counter >>> (8 * i));
            try {
                ChaCha20Poly1305 c = new ChaCha20Poly1305(); c.init(encrypt, new AEADParameters(new KeyParameter(key), 128, nonce, ad));
                byte[] out = new byte[c.getOutputSize(b.length)]; int n = c.processBytes(b, 0, b.length, out, 0); n += c.doFinal(out, n);
                counter++; return Arrays.copyOf(out, n);
            } catch (Exception ex) { throw new Fault("Authentication failed"); }
        }
        public byte[] encrypt(byte[] b, byte[] ad) { return crypt(true, b, ad); }
        public byte[] decrypt(byte[] b, byte[] ad) { return crypt(false, b, ad); }
    }
}
