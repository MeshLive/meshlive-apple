package org.nearbyintercom.core;

import java.util.*;
import static org.nearbyintercom.core.Wire.*;

/** A bounded queue shared by GATT callback writes and the one L2CAP writer thread. */
public final class OrderedWriter {
    private static class Entry { final byte[] bytes; final long time; int offset; Entry(byte[] b, long t) { bytes = b; time = t; } }
    private final ArrayDeque<Entry> entries = new ArrayDeque<>(); private int queued; private boolean cancelled;
    public long submittedBytes, completedEntries;
    public synchronized void enqueue(List<byte[]> items, long now) {
        require(items.size() <= 1024, "Too many queue entries");
        int sum = 0; for (byte[] b : items) { require(b.length > 0 && b.length <= 131072 - sum, "Queue batch too large or empty"); sum += b.length; }
        require(!cancelled && queued + sum <= 131072 && entries.size() + items.size() <= 1024, "Transport queue full or cancelled");
        for (byte[] b : items) entries.add(new Entry(b.clone(), now)); queued += sum; notifyAll();
    }
    public synchronized byte[] peek() {
        Entry e = entries.peek(); return e == null ? null : Arrays.copyOfRange(e.bytes, e.offset, e.bytes.length);
    }
    public synchronized byte[] await() throws InterruptedException { while (entries.isEmpty() && !cancelled) wait(); return cancelled ? null : peek(); }
    public synchronized void consume(int n) {
        if (cancelled) return; Entry e = entries.peek(); require(e != null && n >= 0 && n <= e.bytes.length - e.offset, "Invalid partial write count");
        e.offset += n; queued -= n; submittedBytes += n;
        if (e.offset == e.bytes.length) { entries.remove(); completedEntries++; }
    }
    public synchronized int bytes() { return queued; }
    public synchronized long age(long now) { return entries.isEmpty() ? 0 : Math.max(0, now - entries.peek().time); }
    public synchronized void cancel() { cancelled = true; entries.clear(); queued = 0; notifyAll(); }
}
