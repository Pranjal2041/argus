package dev.universaltmux.android

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

internal sealed interface LabMarkdownBlock {
    data class Heading(val level: Int, val text: String) : LabMarkdownBlock
    data class Paragraph(val text: String) : LabMarkdownBlock
    data class Bullets(val items: List<String>) : LabMarkdownBlock
    data class Quote(val text: String) : LabMarkdownBlock
    data class Code(val text: String) : LabMarkdownBlock
    data class Table(val rows: List<List<String>>) : LabMarkdownBlock
    data object Rule : LabMarkdownBlock
}

private val headingPattern = Regex("^(#{1,6})\\s+(.+)$")
private val bulletPattern = Regex("^\\s*[-+*]\\s+(.+)$")
private val orderedPattern = Regex("^\\s*\\d+[.)]\\s+(.+)$")
private val tableRulePattern = Regex("^:?-{3,}:?$")

internal fun parseLabMarkdown(value: String): List<LabMarkdownBlock> {
    val lines = value.replace("\r\n", "\n").replace('\r', '\n').lines()
    val out = mutableListOf<LabMarkdownBlock>()
    var index = 0
    fun tableCells(line: String) = line.trim().trim('|').split('|').map(String::trim)
    fun isTableRule(line: String) = tableCells(line).isNotEmpty() && tableCells(line).all { tableRulePattern.matches(it) }
    fun startsBlock(at: Int): Boolean {
        if (at >= lines.size) return true
        val line = lines[at]
        return line.isBlank() || headingPattern.matches(line) || bulletPattern.matches(line) ||
            orderedPattern.matches(line) || line.trimStart().startsWith(">") ||
            line.trimStart().startsWith("```") || line.trimStart().startsWith("~~~") ||
            line.trim() == "---" || line.trim() == "***" ||
            (at + 1 < lines.size && line.contains('|') && isTableRule(lines[at + 1]))
    }
    while (index < lines.size) {
        val line = lines[index]
        if (line.isBlank()) { index++; continue }
        val heading = headingPattern.matchEntire(line)
        if (heading != null) {
            out += LabMarkdownBlock.Heading(heading.groupValues[1].length, heading.groupValues[2].trim())
            index++
            continue
        }
        if (line.trim() == "---" || line.trim() == "***") {
            out += LabMarkdownBlock.Rule; index++; continue
        }
        val fence = line.trimStart().takeIf { it.startsWith("```") || it.startsWith("~~~") }
        if (fence != null) {
            val marker = fence.take(3)
            val code = mutableListOf<String>()
            index++
            while (index < lines.size && !lines[index].trimStart().startsWith(marker)) code += lines[index++]
            if (index < lines.size) index++
            out += LabMarkdownBlock.Code(code.joinToString("\n"))
            continue
        }
        if (index + 1 < lines.size && line.contains('|') && isTableRule(lines[index + 1])) {
            val rows = mutableListOf(tableCells(line))
            index += 2
            while (index < lines.size && lines[index].contains('|') && lines[index].isNotBlank()) {
                rows += tableCells(lines[index++])
            }
            out += LabMarkdownBlock.Table(rows)
            continue
        }
        val firstListItem = bulletPattern.matchEntire(line) ?: orderedPattern.matchEntire(line)
        if (firstListItem != null) {
            val items = mutableListOf<String>()
            while (index < lines.size) {
                val match = bulletPattern.matchEntire(lines[index]) ?: orderedPattern.matchEntire(lines[index]) ?: break
                items += match.groupValues[1].trim()
                index++
            }
            out += LabMarkdownBlock.Bullets(items)
            continue
        }
        if (line.trimStart().startsWith(">")) {
            val quote = mutableListOf<String>()
            while (index < lines.size && lines[index].trimStart().startsWith(">")) {
                quote += lines[index++].trimStart().removePrefix(">").trimStart()
            }
            out += LabMarkdownBlock.Quote(quote.joinToString(" "))
            continue
        }
        val paragraph = mutableListOf<String>()
        while (index < lines.size && !startsBlock(index)) paragraph += lines[index++].trim()
        if (paragraph.isEmpty()) {
            paragraph += lines[index++].trim()
        }
        out += LabMarkdownBlock.Paragraph(paragraph.joinToString(" "))
    }
    return out
}

private fun cleanInline(value: String): String = value
    .replace(Regex("!\\[([^]]*)]\\([^)]+\\)"), "$1")
    .replace(Regex("\\[([^]]+)]\\([^)]+\\)"), "$1")

private fun inlineMarkdown(value: String, color: Color): AnnotatedString = buildAnnotatedString {
    val source = cleanInline(value)
    var index = 0
    while (index < source.length) {
        val token = when {
            source.startsWith("**", index) -> "**"
            source.startsWith("__", index) -> "__"
            source.startsWith("~~", index) -> "~~"
            source[index] == '`' -> "`"
            else -> ""
        }
        if (token.isEmpty()) { append(source[index++]); continue }
        val end = source.indexOf(token, index + token.length)
        if (end < 0) { append(token); index += token.length; continue }
        val content = source.substring(index + token.length, end)
        val style = when (token) {
            "**", "__" -> SpanStyle(color = color, fontWeight = FontWeight.Bold)
            "~~" -> SpanStyle(textDecoration = TextDecoration.LineThrough)
            else -> SpanStyle(color = color, fontFamily = FontFamily.Monospace, background = color.copy(alpha = .09f))
        }
        pushStyle(style); append(content); pop()
        index = end + token.length
    }
}

internal fun labMarkdownPlainText(value: String): String = parseLabMarkdown(value).joinToString(" ") { block ->
    val text = when (block) {
        is LabMarkdownBlock.Heading -> block.text
        is LabMarkdownBlock.Paragraph -> block.text
        is LabMarkdownBlock.Bullets -> block.items.joinToString("; ")
        is LabMarkdownBlock.Quote -> block.text
        is LabMarkdownBlock.Code -> block.text
        is LabMarkdownBlock.Table -> block.rows.joinToString("; ") { it.joinToString(" · ") }
        LabMarkdownBlock.Rule -> ""
    }
    cleanInline(text).replace("**", "").replace("__", "").replace("~~", "").replace("`", "")
}.replace(Regex("\\s+"), " ").trim()

@Composable
internal fun LabMarkdown(
    value: String,
    color: Color,
    faint: Color,
    surface: Color,
    modifier: Modifier = Modifier,
) {
    val blocks = parseLabMarkdown(value)
    SelectionContainer {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(7.dp)) {
            blocks.forEach { block ->
                when (block) {
                    is LabMarkdownBlock.Heading -> Text(
                        inlineMarkdown(block.text, color), color = color,
                        fontSize = when (block.level) { 1 -> 20.sp; 2 -> 18.sp; 3 -> 15.sp; else -> 13.sp },
                        fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = if (block.level <= 2) 5.dp else 2.dp),
                    )
                    is LabMarkdownBlock.Paragraph -> Text(inlineMarkdown(block.text, color), color = color, fontSize = 13.sp, lineHeight = 19.sp)
                    is LabMarkdownBlock.Bullets -> Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        block.items.forEach { item -> Row {
                            Text("•", color = faint, modifier = Modifier.width(16.dp))
                            Text(inlineMarkdown(item, color), color = color, fontSize = 13.sp, lineHeight = 18.sp, modifier = Modifier.weight(1f))
                        } }
                    }
                    is LabMarkdownBlock.Quote -> Text(
                        inlineMarkdown(block.text, color), color = faint, fontSize = 13.sp,
                        modifier = Modifier.background(surface, RoundedCornerShape(5.dp)).padding(9.dp),
                    )
                    is LabMarkdownBlock.Code -> Text(
                        block.text, color = color, fontSize = 11.sp, fontFamily = FontFamily.Monospace,
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                            .background(surface, RoundedCornerShape(5.dp)).padding(9.dp),
                    )
                    is LabMarkdownBlock.Table -> {
                        val columns = block.rows.maxOfOrNull { it.size } ?: 0
                        val widths = (0 until columns).map { column ->
                            block.rows.maxOfOrNull { it.getOrNull(column).orEmpty().length }?.coerceIn(8, 28) ?: 8
                        }
                        Column(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
                            block.rows.forEachIndexed { rowIndex, row -> Row(Modifier.background(if (rowIndex == 0) surface else Color.Transparent)) {
                                widths.forEachIndexed { column, width ->
                                    Text(
                                        inlineMarkdown(row.getOrNull(column).orEmpty(), color), color = if (rowIndex == 0) color else faint,
                                        fontSize = 11.sp, fontWeight = if (rowIndex == 0) FontWeight.Bold else FontWeight.Normal,
                                        modifier = Modifier.width((width * 7 + 18).dp).padding(horizontal = 7.dp, vertical = 6.dp),
                                    )
                                }
                            } }
                        }
                    }
                    LabMarkdownBlock.Rule -> Spacer(Modifier.fillMaxWidth().height(1.dp).background(faint.copy(alpha = .35f)))
                }
            }
        }
    }
}
