package com.printcalc.stl_weight

import android.app.Activity
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.MifareClassic
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Spool tags: reads NDEF (OpenSpool JSON, OpenPrintTag CBOR) and Bambu Lab
 * MIFARE Classic tags (sector keys are derived from the tag UID, as documented
 * by the Bambu Research Group), and writes OpenSpool NDEF to blank tags.
 */
class NfcHelper(private val activity: Activity) {
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var writePayload: Pair<String, ByteArray>? = null

    private val adapter: NfcAdapter? get() = NfcAdapter.getDefaultAdapter(activity)

    fun state(): String {
        val a = adapter ?: return "none"
        return if (a.isEnabled) "on" else "off"
    }

    /** Waits for one tag and reads it; result is a map (or null when cancelled). */
    fun read(result: MethodChannel.Result) {
        start(result, null)
    }

    /** Waits for one tag and writes an NDEF record with [mime] and [payload]. */
    fun write(mime: String, payload: ByteArray, result: MethodChannel.Result) {
        start(result, mime to payload)
    }

    fun cancel() {
        stop()
        finish(null)
    }

    private fun start(result: MethodChannel.Result, write: Pair<String, ByteArray>?) {
        val a = adapter
        if (a == null) {
            result.error("nfc", "NFC is not available on this device", null)
            return
        }
        if (!a.isEnabled) {
            result.error("nfc_off", "NFC is turned off", null)
            return
        }
        pending?.success(null)
        pending = result
        writePayload = write
        val flags = NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or NfcAdapter.FLAG_READER_NFC_V
        val extras = Bundle().apply { putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, 250) }
        try {
            a.enableReaderMode(activity, { tag -> onTag(tag) }, flags, extras)
        } catch (e: Exception) {
            pending = null
            result.error("nfc", e.message, null)
        }
    }

    fun stop() {
        try {
            adapter?.disableReaderMode(activity)
        } catch (_: Exception) {
        }
    }

    private fun finish(value: Any?) {
        val r = pending ?: return
        pending = null
        writePayload = null
        main.post { r.success(value) }
    }

    private fun fail(code: String, msg: String?) {
        val r = pending ?: return
        pending = null
        writePayload = null
        main.post { r.error(code, msg, null) }
    }

    private fun onTag(tag: Tag) {
        val w = writePayload
        try {
            val out = if (w == null) readTag(tag) else writeTag(tag, w.first, w.second)
            main.post { stop() }
            finish(out)
        } catch (e: Exception) {
            main.post { stop() }
            fail("nfc_io", e.message ?: e.javaClass.simpleName)
        }
    }

    private fun readTag(tag: Tag): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        out["uid"] = hex(tag.id)
        out["techs"] = tag.techList.map { it.substringAfterLast('.') }
        val ndef = Ndef.get(tag)
        if (ndef != null) {
            var msg: NdefMessage? = ndef.cachedNdefMessage
            if (msg == null) {
                try {
                    ndef.connect()
                    msg = ndef.ndefMessage
                } catch (_: Exception) {
                } finally {
                    try { ndef.close() } catch (_: Exception) {}
                }
            }
            out["writable"] = ndef.isWritable
            out["records"] = msg?.records?.map { r ->
                mapOf("tnf" to r.tnf.toInt(), "type" to String(r.type, Charsets.US_ASCII), "payload" to r.payload)
            } ?: emptyList<Any>()
        }
        val mc = try { MifareClassic.get(tag) } catch (_: Exception) { null }
        if (mc != null) out["mifare"] = readBambu(mc, tag.id)
        else if (tag.techList.any { it.endsWith("MifareClassic") }) out["mifare"] = mapOf("error" to "unsupported")
        return out
    }

    /** Sectors 0..4 of a Bambu Lab tag (blocks 0..19), or an error. */
    private fun readBambu(mc: MifareClassic, uid: ByteArray): Map<String, Any?> {
        val keys = bambuKeys(uid)
        val blocks = ArrayList<ByteArray?>()
        try {
            mc.connect()
            for (sector in 0 until 5) {
                val ok = mc.authenticateSectorWithKeyA(sector, keys[sector])
                if (!ok) {
                    return mapOf("error" to (if (sector == 0) "auth" else "auth$sector"), "blocks" to blocks)
                }
                val first = mc.sectorToBlock(sector)
                for (b in 0 until mc.getBlockCountInSector(sector)) blocks.add(mc.readBlock(first + b))
            }
        } catch (e: Exception) {
            return mapOf("error" to (e.message ?: "io"), "blocks" to blocks)
        } finally {
            try { mc.close() } catch (_: Exception) {}
        }
        return mapOf("blocks" to blocks)
    }

    private fun writeTag(tag: Tag, mime: String, payload: ByteArray): Map<String, Any?> {
        val msg = NdefMessage(arrayOf(NdefRecord.createMime(mime, payload)))
        val ndef = Ndef.get(tag)
        if (ndef != null) {
            ndef.connect()
            try {
                if (!ndef.isWritable) throw IllegalStateException("read-only")
                if (ndef.maxSize < msg.byteArrayLength) throw IllegalStateException("too small")
                ndef.writeNdefMessage(msg)
            } finally {
                try { ndef.close() } catch (_: Exception) {}
            }
        } else {
            val f = NdefFormatable.get(tag) ?: throw IllegalStateException("not NDEF")
            f.connect()
            try {
                f.format(msg)
            } finally {
                try { f.close() } catch (_: Exception) {}
            }
        }
        return mapOf("uid" to hex(tag.id))
    }

    companion object {
        private val BAMBU_SALT = byteArrayOf(
            0x9a.toByte(), 0x75, 0x9c.toByte(), 0xf2.toByte(), 0xc4.toByte(), 0xf7.toByte(), 0xca.toByte(),
            0xff.toByte(), 0x22, 0x2c, 0xb9.toByte(), 0x76, 0x9b.toByte(), 0x41, 0xbc.toByte(), 0x96.toByte(),
        )

        /** HKDF-SHA256(ikm = UID, salt, info = "RFID-A\0") → 16 sector keys of 6 bytes. */
        fun bambuKeys(uid: ByteArray): List<ByteArray> {
            val okm = hkdf(uid, BAMBU_SALT, "RFID-A\u0000".toByteArray(Charsets.US_ASCII), 16 * 6)
            return (0 until 16).map { okm.copyOfRange(it * 6, it * 6 + 6) }
        }

        private fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, len: Int): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(salt, "HmacSHA256"))
            val prk = mac.doFinal(ikm)
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            val out = java.io.ByteArrayOutputStream()
            var t = ByteArray(0)
            var i = 1
            while (out.size() < len) {
                mac.update(t)
                mac.update(info)
                mac.update(i.toByte())
                t = mac.doFinal()
                out.write(t)
                i++
            }
            return out.toByteArray().copyOf(len)
        }

        fun hex(b: ByteArray): String = b.joinToString("") { "%02X".format(it) }
    }
}
