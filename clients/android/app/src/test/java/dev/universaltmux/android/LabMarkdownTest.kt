package dev.universaltmux.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LabMarkdownTest {
    private val report = """
        ## R11 — Corrected raw-Kimi action evaluation

        **Status:** ✅ Completed (`exit 0`, 37m19s)

        | Model | Mode | Valid | Acc@100 |
        |---|---:|---:|---:|
        | Step 110 | Dense | 493/500 | **49.90%** |
        | Step 900 | Dense | 470/500 | 44.68% |

        - **Dense:** +7.2 pp.
        - No runtime errors.
    """.trimIndent()

    @Test
    fun parsesTheBlocksUsedByLabReports() {
        val blocks = parseLabMarkdown(report)

        assertTrue(blocks.first() is LabMarkdownBlock.Heading)
        assertTrue(blocks.any { it is LabMarkdownBlock.Table })
        assertTrue(blocks.any { it is LabMarkdownBlock.Bullets })
        assertEquals(3, (blocks.first { it is LabMarkdownBlock.Table } as LabMarkdownBlock.Table).rows.size)
    }

    @Test
    fun previewTextDropsMarkdownSyntaxWithoutDroppingValues() {
        val plain = labMarkdownPlainText(report)

        assertTrue(plain.contains("R11 — Corrected raw-Kimi action evaluation"))
        assertTrue(plain.contains("Step 110 · Dense · 493/500 · 49.90%"))
        assertFalse(plain.contains("##"))
        assertFalse(plain.contains("**"))
        assertFalse(plain.contains("|---"))
    }
}
