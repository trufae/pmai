package org.mai.kotlin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class Attachment(val path: String, val name: String, val mime: String) {
    fun json() = JSONObject().put("path", path).put("name", name).put("mime", mime)
    companion object {
        fun decode(json: String) = JSONArray(json).objects().map { Attachment(it.getString("path"), it.getString("name"), it.getString("mime")) }
        fun encode(items: List<Attachment>) = JSONArray().also { array -> items.forEach { array.put(it.json()) } }.toString()
    }
}

internal object AttachmentImporter {
    fun import(context: Context, uri: Uri, remote: Boolean): List<Attachment> {
        val root = context.filesDir.resolve("pocketmai/incoming").apply { mkdirs() }
        val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }?.substringAfterLast('/')?.substringAfterLast('\\') ?: "document"
        val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
        if (mime.startsWith("image/")) {
            require(!remote) { "This remote host accepts text documents. Use a local vision model for photos." }
            val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
                val scale = minOf(1.0, 2048.0 / maxOf(info.size.width, info.size.height))
                decoder.setTargetSize(maxOf(1, (info.size.width * scale).toInt()), maxOf(1, (info.size.height * scale).toInt()))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
            val file = root.resolve("${UUID.randomUUID()}.jpg")
            try { file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)) } }
            finally { bitmap.recycle() }
            return listOf(Attachment(file.path, "${name.substringBeforeLast('.', name)}.jpg", "image/jpeg"))
        }
        val file = root.resolve("${UUID.randomUUID()}.document")
        try {
            requireNotNull(context.contentResolver.openInputStream(uri)).use { input ->
                file.outputStream().use { output ->
                    var total = 0; val buffer = ByteArray(16384)
                    while (true) {
                        val count = input.read(buffer); if (count == -1) break
                        total += count; require(total <= 25_000_000) { "Attachments are limited to 25 MB." }
                        output.write(buffer, 0, count)
                    }
                }
            }
            if (mime == "application/pdf" || name.endsWith(".pdf", true)) {
                PDFBoxResourceLoader.init(context.applicationContext)
                val text = PDDocument.load(file).use { document ->
                    require(!document.isEncrypted) { "Unlock this PDF before attaching it." }
                    require(document.numberOfPages <= 200) { "PDFs are limited to 200 pages." }
                    PDFTextStripper().getText(document)
                }
                if (text.isNotBlank()) {
                    require(text.toByteArray().size <= 1_500_000) { "The extracted document text exceeds 1.5 MB." }
                    file.writeText(text)
                    return listOf(Attachment(file.path, "$name.md", "text/markdown"))
                }
                require(!remote) { "This scanned PDF has no text. Attach it to a local vision model." }
                val pages = mutableListOf<Attachment>()
                try {
                    ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                        PdfRenderer(descriptor).use { renderer ->
                            require(renderer.pageCount in 1..12) { "Scanned PDFs are limited to 12 pages." }
                            for (index in 0 until renderer.pageCount) renderer.openPage(index).use { page ->
                                val scale = 1600.0 / maxOf(page.width, page.height)
                                val bitmap = Bitmap.createBitmap(maxOf(1, (page.width * scale).toInt()), maxOf(1, (page.height * scale).toInt()), Bitmap.Config.ARGB_8888)
                                val image = root.resolve("${UUID.randomUUID()}.jpg")
                                try {
                                    Canvas(bitmap).drawColor(Color.WHITE)
                                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    image.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it)) }
                                    pages.add(Attachment(image.path, "$name · page ${index + 1}", "image/jpeg"))
                                } finally { bitmap.recycle() }
                            }
                        }
                    }
                } catch (error: Exception) { pages.forEach { File(it.path).delete() }; throw error }
                file.delete()
                return pages
            }
            return listOf(Attachment(file.path, name, mime))
        } catch (error: Exception) { file.delete(); throw error }
    }
}
