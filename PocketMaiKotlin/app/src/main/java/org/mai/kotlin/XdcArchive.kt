package org.mai.kotlin

import java.io.File
import java.io.InputStream
import java.util.zip.ZipInputStream

/** Extract only regular files into a fresh private directory, with bounded IO. */
internal object XdcArchive {
    const val maxFileBytes = 4_000_000
    const val maxTotalBytes = 32_000_000
    const val maxFiles = 200

    fun extract(input: InputStream, destination: File) {
        require(!destination.exists()) { "App destination already exists" }
        check(destination.mkdirs()) { "Cannot create app directory" }
        try {
            val root = destination.canonicalFile
            var total = 0
            var count = 0
            val names = mutableSetOf<String>()
            ZipInputStream(input).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    require(++count <= maxFiles) { "WebXDC apps may contain at most $maxFiles entries" }
                    require(entry.name.isNotBlank() && !entry.name.startsWith('/') && !entry.name.contains('\\') && !entry.name.contains(':')) { "Invalid archive path" }
                    val target = File(root, entry.name).canonicalFile
                    require(target.path.startsWith(root.path + File.separator)) { "Archive path escapes the app" }
                    require(names.add(target.path)) { "Duplicate archive path" }
                    if (entry.isDirectory) { check(target.mkdirs() || target.isDirectory); continue }
                    target.parentFile?.let { check(it.mkdirs() || it.isDirectory) }
                    var size = 0
                    target.outputStream().use { output ->
                        val buffer = ByteArray(16 * 1024)
                        while (true) {
                            val n = zip.read(buffer)
                            if (n == -1) break
                            size += n; total += n
                            require(size <= maxFileBytes && total <= maxTotalBytes) { "WebXDC app exceeds its size limit" }
                            output.write(buffer, 0, n)
                        }
                    }
                }
            }
            require(File(root, "index.html").isFile) { "A WebXDC archive must contain index.html at its root" }
        } catch (error: Exception) {
            destination.deleteRecursively()
            throw error
        }
    }
}
