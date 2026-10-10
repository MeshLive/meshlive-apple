package com.example.bluetoothtest

// Cross-language vectors for experimental peer labels (naming phase 1), using the Android patch's own
// LabelText.kt / SignedLabel.kt / TitlePage.kt (copied unchanged from the patch). Not shipped.

import java.io.File
import java.util.UUID

private fun hx(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
private fun uhx(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
private fun js(s: String): String {
    val b = StringBuilder("\"")
    for (c in s) when {
        c == '"' -> b.append("\\\"")
        c == '\\' -> b.append("\\\\")
        c.code < 0x20 || c.code > 0x7e -> b.append("\\u%04x".format(c.code))
        else -> b.append(c)
    }
    return b.append('"').toString()
}

/** Text-rule cases: Swift must reach the same verdict (shared table beyond LabelTextTest). */
private val TEXT_CASES = listOf(
    "Asha", "Brave Tiger", "Mike Foster", " Asha", "Asha ", "Asha  Rao", "é", "été", "M6SC7-N75YR", "m6sc7n75yr",
    "ab12c", "abcde-fghij", "Ｍ6SC7-N75YR", "Asha ✓", "Asha ✅", "Asha‮evil", "A‍sha", "pаypal",
    "Alαn", "Ravi राम", "Алекс", "Tokyo 東京です", "Ар रा",
    "محمد", "Ali محمد", "محمد रा", "한국 Seoul 漢",
    "สวัสดี", "Zx̀́̂", "Zx̀́̂̃", "שלום 123",
    "😀 party", "Team 7", "12345", "ABCDE", "a b", "a\tb", "x\u0085y", "priv", "Café Über",
    "Σωκράτης", "Naïve 2", "こんにちは", "你好ㄅㄆ ok",
    "Water at the school", "a".repeat(32), "a".repeat(33), "€".repeat(10) + "ab", "Flood ⚠ update",
)

fun main(args: Array<String>) {
    if (args.isNotEmpty() && args[0] == "verify") { verify(File(args[1]).readText()); return }
    val alice = KeyPairSigningIdentity(generateEcKeyPair())
    val callId = UUID.fromString("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")
    val streamId = UUID.fromString("11223344-5566-7788-99aa-bbccddeeff00")
    val name = SignedLabelCodec.sign(alice, LabelKind.PERSON_NAME, LabelBinding.call(callId), "Asha Rao")
    val subject = SignedLabelCodec.sign(alice, LabelKind.CALL_SUBJECT, LabelBinding.call(callId), "Water at the school")
    val title = SignedLabelCodec.sign(alice, LabelKind.STREAM_TITLE, LabelBinding.stream(streamId), "Flood update")
    val direct = SignedLabelCodec.sign(alice, LabelKind.STREAM_TITLE, LabelBinding.DIRECT_STREAM, "Market news", sequence = 7)
    val container = SignedLabelCodec.encodeContainer(listOf(name, subject))
    val pages = TitlePageCodec.pages(0x81234567.toInt(), "a".repeat(18) + "€".repeat(10))
    val cases = TEXT_CASES.map { text ->
        val kind = if (text.length > 40) LabelKind.CALL_SUBJECT else LabelKind.PERSON_NAME
        val verdict = LabelText.rejection(kind, text)
        "{\"text\": ${js(text)}, \"kind\": ${kind.wireValue}, \"rejection\": ${if (verdict == null) "null" else js(verdict)}}"
    }
    println("""{
"spki": "${hx(alice.publicKeyEncoded)}", "signer": "${alice.nodeId}",
"callId": "$callId", "streamId": "$streamId",
"name": "${hx(name)}", "subject": "${hx(subject)}", "title": "${hx(title)}", "direct": "${hx(direct)}",
"container": "${hx(container)}",
"pages": [${pages.joinToString(", ") { "\"${hx(it)}\"" }}],
"textCases": [${cases.joinToString(",\n")}]
}""")
}

private fun verify(text: String) {
    fun field(n: String) = Regex("\"$n\"\\s*:\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]
    val signer = NodeId.fromPublicKey(uhx(field("spki")))
    val callId = UUID.fromString(field("callId")); val streamId = UUID.fromString(field("streamId"))
    val name = SignedLabelCodec.decode(uhx(field("name")))
    check(SignedLabelCodec.verify(name, signer, LabelBinding.call(callId)) == LabelKind.PERSON_NAME)
    val subject = SignedLabelCodec.decode(uhx(field("subject")))
    check(SignedLabelCodec.verify(subject, signer, LabelBinding.call(callId)) == LabelKind.CALL_SUBJECT)
    val title = SignedLabelCodec.decode(uhx(field("title")))
    check(SignedLabelCodec.verify(title, signer, LabelBinding.stream(streamId)) == LabelKind.STREAM_TITLE)
    check(runCatching { SignedLabelCodec.verify(title, signer, LabelBinding.DIRECT_STREAM) }.isFailure)
    val inbox = LabelInbox()
    check(inbox.accept(uhx(field("container")), signer, LabelBinding.call(callId), "verify").size == 2)
    println("Swift labels verified by Android classes: ${name.text} / ${subject.text} / ${title.text}; container ok")
}
