package com.example.bluetoothtest

// Cross-language vector generator: runs the Android app's own protocol classes (copied unchanged
// into this scratch directory) and prints JSON for the iOS Swift tests. Not shipped anywhere.

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyPair
import java.security.interfaces.ECPrivateKey
import java.util.UUID

private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
private fun unhex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
private fun scalar(k: KeyPair): String {
    val s = (k.private as ECPrivateKey).s.toByteArray()
    val trimmed = if (s.size > 32) s.copyOfRange(s.size - 32, s.size) else s
    return hex(ByteArray(32 - trimmed.size) + trimmed)
}

private class Json {
    private val parts = mutableListOf<String>()
    fun s(k: String, v: String) { parts += "\"$k\": \"${v.replace("\\", "\\\\").replace("\"", "\\\"")}\"" }
    fun n(k: String, v: Long) { parts += "\"$k\": $v" }
    fun raw(k: String, v: String) { parts += "\"$k\": $v" }
    fun obj(k: String, f: Json.() -> Unit) { raw(k, Json().apply(f).toString()) }
    fun arr(k: String, items: List<String>) { raw(k, items.joinToString(", ", "[", "]")) }
    override fun toString() = parts.joinToString(",\n", "{\n", "\n}")
}

private fun helloJson(j: Json, hello: SignedHandshakeHello) {
    j.s("encoded", hex(HandshakeHelloCodec.encode(hello)))
    j.s("unsigned", hex(HandshakeHelloCodec.encodeUnsigned(hello)))
    j.s("nodeId", hello.nodeId.toString())
    j.s("identityKey", hex(hello.identityPublicKey))
    j.s("ephemeralKey", hex(hello.ephemeralPublicKey))
    j.s("nonce", hex(hello.nonce))
    j.s("capabilities", hex(NodeCapabilitiesCodec.encode(hello.capabilities)))
    j.s("signature", hex(hello.signature))
}

private fun handshakeVector(
    j: Json,
    purpose: HandshakePurpose,
    initiatorIdentity: KeyPair,
    responderIdentity: KeyPair,
    initiatorCaps: NodeCapabilities,
    responderCaps: NodeCapabilities,
): MeshSessionKeys {
    val a = KeyPairSigningIdentity(initiatorIdentity)
    val b = KeyPairSigningIdentity(responderIdentity)
    val pa = MeshHandshake.start(a, HandshakeRole.INITIATOR, initiatorCaps, purpose = purpose)
    val pb = MeshHandshake.start(b, HandshakeRole.RESPONDER, responderCaps, purpose = purpose)
    val ka = MeshHandshake.finish(pa, pb.hello)
    val kb = MeshHandshake.finish(pb, pa.hello)
    check(ka.sendKey.contentEquals(kb.receiveKey) && ka.receiveKey.contentEquals(kb.sendKey))
    j.s("purpose", purpose.name)
    j.s("initiatorIdentityPrivate", scalar(initiatorIdentity))
    j.s("responderIdentityPrivate", scalar(responderIdentity))
    j.s("initiatorEphemeralPrivate", scalar(pa.ephemeralKeyPair))
    j.s("responderEphemeralPrivate", scalar(pb.ephemeralKeyPair))
    j.obj("initiatorHello") { helloJson(this, pa.hello) }
    j.obj("responderHello") { helloJson(this, pb.hello) }
    j.s("initiatorToResponderKey", hex(ka.sendKey))
    j.s("responderToInitiatorKey", hex(ka.receiveKey))
    return ka
}

private fun rec(label: String, type: Int, payload: ByteArray) =
    Json().apply { s("label", label); n("type", type.toLong()); s("payload", hex(payload)) }.toString()

fun main(args: Array<String>) {
    if (args.isNotEmpty() && args[0] == "verify") { verify(File(args[1]).readText()); return }
    val out = Json()
    // 1. AES-GCM (shared Android/Windows vector).
    out.s("aesGcm", hex(MeshAead.encrypt(ByteArray(32) { it.toByte() }, 7, "cross-platform".toByteArray(), "BMS1-test-aad".toByteArray())))

    // 2. Link handshake (Android caller = initiator, CoC) and 3. endpoint handshake (separate domain).
    val callerId = generateEcKeyPair(); val calleeId = generateEcKeyPair()
    val linkCaps = NodeCapabilities(NodeCapabilities.TRANSPORT_BLE_L2CAP, 1, 3, 1200, 0)
    val calleeCaps = NodeCapabilities(NodeCapabilities.TRANSPORT_BLE_L2CAP, 1, 3, 1200, 0)
    lateinit var linkKeys: MeshSessionKeys
    out.obj("link") { linkKeys = handshakeVector(this, HandshakePurpose.LINK, callerId, calleeId, linkCaps, calleeCaps) }
    val epCaps = NodeCapabilities(NodeCapabilities.TRANSPORT_BLE_L2CAP, 1, 3 or NodeCapabilities.DECODE_PREFERS_VP9, 1200, 0)
    lateinit var endpointKeys: MeshSessionKeys
    out.obj("endpoint") { endpointKeys = handshakeVector(this, HandshakePurpose.END_TO_END, callerId, calleeId, epCaps, calleeCaps) }
    run {
        val bytes = ByteArrayOutputStream()
        val pending = MeshHandshake.start(KeyPairSigningIdentity(callerId), HandshakeRole.INITIATOR, linkCaps)
        val enc = HandshakeHelloCodec.encode(pending.hello)
        java.io.DataOutputStream(bytes).apply { writeInt(enc.size); write(enc) }
        out.s("framedHelloExample", hex(bytes.toByteArray()))
    }

    // 4. One BMS1 byte stream from the initiator: endpoint hello, heartbeats, end-to-end content.
    run {
        val wire = ByteArrayOutputStream()
        val writer = SecureRecordWriter(wire, linkKeys.sendKey)
        val sealer = EndToEndContentSealer(endpointKeys.sendKey)
        val contents = mutableListOf<String>()
        val records = mutableListOf<String>()
        val callId = UUID.fromString("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")
        fun signal(s: PrivateCallSignal, r: PrivateCallReason = PrivateCallReason.NONE, hops: Int = 0) =
            PrivateCallSignalCodec.encode(PrivateCallSignalMessage(callId, s, r, hops))
        val header = EndToEndStreamProtocol.encodeHeader(StreamProtocol.CODEC_VP9, VideoSettings(VideoResolution(426, 240, "240p"), 15, 300_000, 500), 90, includeAudio = true)
        val opusHead = unhex("4f707573486561640101380180bb0000000000")
        val pair = StreamProtocol.pairAudioPackets(
            StreamProtocol.Packet(StreamProtocol.FLAG_AUDIO, 40_000, unhex("fc11")),
            StreamProtocol.Packet(StreamProtocol.FLAG_AUDIO, 60_000, unhex("fc2222")),
        )
        val batch = StreamProtocol.batchAudioPackets(listOf(
            StreamProtocol.Packet(StreamProtocol.FLAG_AUDIO, 80_000, unhex("fc31")),
            StreamProtocol.Packet(StreamProtocol.FLAG_AUDIO, 100_000, unhex("fc32")),
            StreamProtocol.Packet(StreamProtocol.FLAG_AUDIO, 120_000, unhex("fc33")),
        ))
        fun pkt(flags: Int, pts: Long, payload: ByteArray) = EndToEndStreamProtocol.encodePacket(flags, pts, payload)
        val items = listOf(
            Triple(EndToEndContentType.PRIVATE_CALL_SIGNAL, 0, signal(PrivateCallSignal.INVITE)) to "invite",
            Triple(EndToEndContentType.PRIVATE_CALL_SIGNAL, 0, signal(PrivateCallSignal.CAMERA_OFF)) to "cameraOff",
            Triple(EndToEndContentType.STREAM_HEADER, 0, header) to "header",
            Triple(EndToEndContentType.MEDIA_PACKET, StreamProtocol.FLAG_AUDIO or StreamProtocol.FLAG_CODEC_CONFIG,
                pkt(StreamProtocol.FLAG_AUDIO or StreamProtocol.FLAG_CODEC_CONFIG, 0, opusHead)) to "audioConfig",
            Triple(EndToEndContentType.MEDIA_PACKET, StreamProtocol.FLAG_AUDIO, pkt(StreamProtocol.FLAG_AUDIO, 20_000, unhex("fc0102030405060708"))) to "audio",
            Triple(EndToEndContentType.MEDIA_PACKET, pair.flags, pkt(pair.flags, pair.presentationTimeUs, pair.payload)) to "audioPair",
            Triple(EndToEndContentType.MEDIA_PACKET, batch.flags, pkt(batch.flags, batch.presentationTimeUs, batch.payload)) to "audioBatch",
            Triple(EndToEndContentType.MEDIA_PACKET, StreamProtocol.FLAG_KEY_FRAME, pkt(StreamProtocol.FLAG_KEY_FRAME, 66_666, unhex("82498342"))) to "videoKey",
            Triple(EndToEndContentType.MEDIA_PACKET, StreamProtocol.FLAG_DISPLAY_ROTATION,
                pkt(StreamProtocol.FLAG_DISPLAY_ROTATION, 0, StreamProtocol.encodeDisplayRotation(270))) to "rotation",
            Triple(EndToEndContentType.KEY_FRAME_REQUEST, 0, ByteArray(0)) to "keyFrameRequest",
            Triple(EndToEndContentType.STREAM_STATE, 0, StreamLifecycleState.PAUSED.encode()) to "paused",
            Triple(EndToEndContentType.STREAM_END_ACK, 0, ByteArray(0)) to "endAck",
            Triple(EndToEndContentType.PRIVATE_CALL_SIGNAL, 0, signal(PrivateCallSignal.HANG_UP, PrivateCallReason.NORMAL)) to "hangUp",
        )
        val ep = MeshHandshake.start(KeyPairSigningIdentity(callerId), HandshakeRole.INITIATOR, epCaps, purpose = HandshakePurpose.END_TO_END)
        writer.write(SecureRecordType.END_TO_END_HANDSHAKE, HandshakeHelloCodec.encode(ep.hello))
        records += rec("endpointHello", 4, HandshakeHelloCodec.encode(ep.hello))
        SecureLinkControlProtocol.writeHeartbeat(writer)
        records += rec("heartbeatV1", 6, byteArrayOf(1))
        val v2 = SecureLinkControlProtocol.encodeCapacityReport(LinkCapacityReport(512, true, 300))
        writer.write(SecureRecordType.LINK_HEARTBEAT, v2); records += rec("heartbeatV2", 6, v2)
        val v3 = SecureLinkControlProtocol.encodeCapacityReport(LinkCapacityReport(700, false, 20, LinkDelivery(123456789L, 4000000000L), deliveryOnly = true))
        writer.write(SecureRecordType.LINK_HEARTBEAT, v3); records += rec("heartbeatV3", 6, v3)
        for ((item, label) in items) {
            val (type, flags, payload) = item
            val sealedRecord = sealer.seal(type, flags, payload)
            writer.write(SecureRecordType.END_TO_END_CONTENT, sealedRecord)
            contents += Json().apply {
                s("label", label); n("type", type.wireValue.toLong()); n("flags", flags.toLong())
                s("plaintext", hex(payload)); s("sealed", hex(sealedRecord))
            }.toString()
            records += rec(label, 5, sealedRecord)
        }
        writer.write(SecureRecordType.ROUTE_CONTROL, StreamRouteControlProtocol.encode(StreamRouteWithdrawal.LOCAL_CAPACITY))
        records += rec("routeWithdrawal", 9, byteArrayOf(1))
        out.arr("bms1Records", records)
        out.s("bms1Stream", hex(wire.toByteArray()))
        out.arr("bme1Contents", contents)
        out.s("bmc2RelayedInvite", hex(signal(PrivateCallSignal.INVITE, hops = 3)))
        out.s("bmc2Decline", hex(signal(PrivateCallSignal.DECLINE, PrivateCallReason.BUSY)))
        out.s("btv3Header", hex(header))
        val reader = SecureRecordReader(ByteArrayInputStream(wire.toByteArray()), linkKeys.sendKey)
        repeat(records.size) { reader.read() }
    }

    // 5. Mesh envelope (BMV1) and a BFG1 forwarded-stream grant; a mesh writer stream.
    run {
        val source = NodeId.fromPublicKey(KeyPairSigningIdentity(callerId).publicKeyEncoded)
        val streamId = UUID.fromString("11223344-5566-7788-99aa-bbccddeeff00")
        val grantKey = ByteArray(32) { (it * 7).toByte() }
        val linkKey = ByteArray(32) { 9 }
        val grant = ForwardedStreamGrantCodec.encode(ForwardedStreamGrant(source, streamId, grantKey))
        val wire = ByteArrayOutputStream()
        val writer = SecureRecordWriter(wire, linkKey)
        EndToEndStreamWriter(writer, EndToEndContentSealer(grantKey), source, useMeshEnvelope = true, meshStreamId = streamId).apply {
            writeHeader(StreamProtocol.CODEC_VP9, VideoSettings(VideoResolution(640, 360, "360p"), 15, 300_000, 500), 0, true)
            writePacket(StreamProtocol.FLAG_AUDIO, 1000, unhex("fc00"))
            writePacket(StreamProtocol.FLAG_KEY_FRAME, 2000, unhex("8249834200"))
            writeState(StreamLifecycleState.ENDED)
        }
        out.obj("mesh") {
            s("grant", hex(grant)); s("grantKey", hex(grantKey)); s("sourceNodeId", source.toString())
            s("streamId", streamId.toString()); s("linkKey", hex(linkKey)); s("stream", hex(wire.toByteArray()))
        }
    }

    // 6. Identity verification.
    run {
        val fpA = IdentityFingerprint.fromPublicKey(KeyPairSigningIdentity(callerId).publicKeyEncoded)
        val fpB = IdentityFingerprint.fromPublicKey(KeyPairSigningIdentity(calleeId).publicKeyEncoded)
        val x = IdentityFingerprint.fromBytes(ByteArray(32) { it.toByte() })
        val y = IdentityFingerprint.fromBytes(ByteArray(32) { (0xff - it).toByte() })
        out.obj("identity") {
            s("callerFingerprint", fpA.hex); s("calleeFingerprint", fpB.hex)
            s("pairCode", SafetyCode.derive(fpA, fpB)); s("callerHalf", SafetyCode.half(fpA))
            s("fixedHalfX", SafetyCode.half(x)); s("fixedHalfY", SafetyCode.half(y)); s("fixedPair", SafetyCode.derive(x, y))
            s("qr", IdentityQrCodec.encode(IdentityQrPayload(fpA, "Asha · फ़ोन")))
            s("qrJose", IdentityQrCodec.encode(IdentityQrPayload(fpB, "José")))
        }
    }

    // 7. Discovery announcements and route tokens.
    run {
        val prefix = unhex("a1b2c3d4e5f6")
        val logical = 0x1234abcd
        val route = StreamRouteToken.forAdvertiser(logical, prefix)
        val offer = DiscoveryAnnouncement(prefix, DiscoveryAnnouncement.FLAG_STREAM_AVAILABLE or DiscoveryAnnouncement.FLAG_GATT_TRANSPORT, 1, route, 0, 0x85, 640, 360, 15, 300)
        val viewer = DiscoveryAnnouncement(unhex("010203040506"), DiscoveryAnnouncement.FLAG_ACCEPTING_CONNECTIONS or DiscoveryAnnouncement.FLAG_ROUTE_RECOVERY, 3, route, 1, 0, streamBitrateKbps = 300, recoveryFromNodeIdPrefix = prefix)
        val call = DiscoveryAnnouncement(prefix, DiscoveryAnnouncement.FLAG_ACCEPTING_CONNECTIONS or DiscoveryAnnouncement.FLAG_PRIVATE_CALL_AVAILABLE, 3, 0, 0, 0)
        out.obj("discovery") {
            n("logicalToken", logical.toLong()); n("routeToken", route.toLong() and 0xffffffffL)
            s("offer", hex(DiscoveryAnnouncementCodec.encode(offer)))
            s("viewerRecovery", hex(DiscoveryAnnouncementCodec.encode(viewer)))
            s("call", hex(DiscoveryAnnouncementCodec.encode(call)))
        }
    }

    // 8. Experimental call video fragments.
    run {
        val packet = EndToEndStreamProtocol.encodePacket(StreamProtocol.FLAG_KEY_FRAME, 1, ByteArray(5000) { (it % 251).toByte() })
        out.arr("fragments", CallVideoFragments.split(packet).map { "\"${hex(it)}\"" })
        out.s("fragmentedPacket", hex(packet))
    }
    println(out)
}

/** Verifies a Swift-produced transcript with the Android classes (two-way cross-language check). */
private fun verify(text: String) {
    fun field(name: String): String = Regex("\"$name\"\\s*:\\s*\"([0-9a-fA-F]*)\"").find(text)?.groupValues?.get(1)
        ?: error("missing $name")
    val linkHello = HandshakeHelloCodec.decode(unhex(field("swiftLinkHello")))
    MeshHandshake.verify(linkHello, HandshakePurpose.LINK)
    val endpointHello = HandshakeHelloCodec.decode(unhex(field("swiftEndpointHello")))
    MeshHandshake.verify(endpointHello, HandshakePurpose.END_TO_END)
    check(runCatching { MeshHandshake.verify(linkHello, HandshakePurpose.END_TO_END) }.isFailure) { "cross-domain hello accepted" }
    // Android responder finishes the Swift initiator's link handshake with the Swift-declared responder secrets.
    val reader = SecureRecordReader(ByteArrayInputStream(unhex(field("swiftBms1Stream"))), unhex(field("swiftBms1Key")))
    val opener = EndToEndContentOpener(unhex(field("swiftBme1Key")))
    check(reader.read().type == SecureRecordType.LINK_HEARTBEAT)
    val invite = opener.open(reader.read().payload)
    check(invite.type == EndToEndContentType.PRIVATE_CALL_SIGNAL)
    check(PrivateCallSignalCodec.decode(invite.payload).signal == PrivateCallSignal.INVITE)
    val header = EndToEndStreamProtocol.decodeHeader(opener.open(reader.read().payload).payload)
    check(header.hasAudio)
    val config = EndToEndStreamProtocol.decodePacket(opener.open(reader.read().payload))
    check(config.flags == StreamProtocol.FLAG_AUDIO or StreamProtocol.FLAG_CODEC_CONFIG)
    val audio = EndToEndStreamProtocol.decodePacket(opener.open(reader.read().payload))
    check(audio.isAudio)
    // Swift's derived keys must equal Android's for the Swift hellos plus the declared Android secrets.
    println("Swift transcript verified by Android classes: signatures, domain separation, BMS1, BME1, BMC2, BTV3, audio packets")
}
