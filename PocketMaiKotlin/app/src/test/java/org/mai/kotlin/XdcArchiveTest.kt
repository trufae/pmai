package org.mai.kotlin

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import java.io.ByteArrayOutputStream

class XdcArchiveTest {
    private fun archive(vararg entries: Pair<String, String>): ByteArray {
        val bytes = ByteArrayOutputStream()
        ZipOutputStream(bytes).use { zip -> entries.forEach { (path, content) ->
            zip.putNextEntry(ZipEntry(path)); zip.write(content.toByteArray()); zip.closeEntry()
        } }
        return bytes.toByteArray()
    }
    @Test fun importsOfflineAppAssets() {
        val root = Files.createTempDirectory("xdc-test").toFile()
        try {
            XdcArchive.extract(ByteArrayInputStream(archive("index.html" to "<h1>Hello</h1>", "js/app.js" to "let x=1")), root.resolve("app"))
            assertEquals("let x=1", root.resolve("app/js/app.js").readText())
        } finally { root.deleteRecursively() }
    }
    // Prevent imported apps overwriting other apps, credentials or host files.
    @Test fun rejectsTraversalAndRemovesPartialImport() {
        val root = Files.createTempDirectory("xdc-test").toFile()
        try {
            assertThrows(IllegalArgumentException::class.java) {
                XdcArchive.extract(ByteArrayInputStream(archive("index.html" to "ok", "../outside" to "bad")), root.resolve("app"))
            }
            assertFalse(root.resolve("outside").exists())
            assertFalse(root.resolve("app").exists())
        } finally { root.deleteRecursively() }
    }
    @Test fun rejectsOversizedExpandedFile() {
        val root = Files.createTempDirectory("xdc-test").toFile()
        try {
            assertThrows(IllegalArgumentException::class.java) {
                XdcArchive.extract(ByteArrayInputStream(archive("index.html" to "x".repeat(XdcArchive.maxFileBytes + 1))), root.resolve("app"))
            }
            assertFalse(root.resolve("app").exists())
        } finally { root.deleteRecursively() }
    }
}
