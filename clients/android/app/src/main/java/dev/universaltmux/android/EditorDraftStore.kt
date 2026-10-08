package dev.universaltmux.android

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

data class EditorDraft(val revision: String, val base: String, val text: String)

/** Draft lifetime is a document, not a composable. Each atomic file retains the
 * exact remote base so a recovered draft can still be conditionally saved. */
class EditorDraftStore(private val root: File) {
    private fun path(identity: String, path: String): File {
        val hash = MessageDigest.getInstance("SHA-256").digest("$identity\u0000$path".toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(root, "$hash.json")
    }
    fun read(identity: String, path: String): EditorDraft? {
        val file = path(identity, path)
        if (!file.exists()) return null
        val objectValue = JSONObject(file.readText())
        check(objectValue.getString("identity") == identity && objectValue.getString("path") == path) { "Draft identity mismatch" }
        return EditorDraft(objectValue.getString("revision"), objectValue.getString("base"), objectValue.getString("text"))
    }
    fun save(identity: String, path: String, draft: EditorDraft) {
        check(root.isDirectory || root.mkdirs()) { "Could not create draft storage" }
        val body = JSONObject().put("identity", identity).put("path", path).put("revision", draft.revision)
            .put("base", draft.base).put("text", draft.text).toString().toByteArray()
        val target = path(identity, path)
        val temporary = File.createTempFile("draft-", ".tmp", root)
        try {
            FileOutputStream(temporary).use { it.write(body); it.fd.sync() }
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { temporary.delete() }
    }
    fun remove(identity: String, path: String) {
        val file = path(identity, path)
        check(!file.exists() || file.delete()) { "Could not clear saved draft" }
    }
}
