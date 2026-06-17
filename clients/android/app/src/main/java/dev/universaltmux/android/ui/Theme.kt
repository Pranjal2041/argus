package dev.universaltmux.android

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/// A full color scheme for the Android client. Chrome roles cover every surface used
/// across the screens; `ansi` (16) + termFg/termBg/termCursor drive the terminal.
/// `Argus` holds the EXACT current literals so the default looks unchanged.
data class ThemePalette(
    val id: String,
    val name: String,
    val isLight: Boolean,
    val bg: Color,        // main background (command center, sidebar)
    val bgDeep: Color,    // deeper background (files / ports content)
    val panel: Color,     // sidebar / surface panels
    val panelAlt: Color,  // command-center card panel
    val text: Color,      // primary text
    val dim: Color,       // secondary text
    val faint: Color,     // tertiary text / borders
    val accent: Color,
    val working: Color,
    val waiting: Color,
    val milestone: Color,
    val bad: Color,
    val look: Color,
    val unseen: Color,
    val idle: Color,
    val live: Color,      // ports "reachable" green
    val selection: Color, // active row fill
    val border: Color,
    // terminal
    val termBg: Color,
    val termFg: Color,
    val termCursor: Color,
    val ansi: List<Color>, // 16 ANSI colors
) {
    companion object {
        private fun c(hex: Long) = Color(hex or 0xFF000000)
        private fun ansiOf(vararg hex: Long) = hex.map { c(it) }

        // THE DEFAULT — exact current Android literals. Do not change.
        val argus = ThemePalette(
            "argus", "Argus", false,
            bg = c(0x1A1B26), bgDeep = c(0x0D0E12), panel = c(0x16161E), panelAlt = c(0x1E1F2B),
            text = c(0xC0CAF5), dim = c(0x9AA5CE), faint = c(0x565F89), accent = c(0x7AA2F7),
            working = c(0x7AA2F7), waiting = c(0xE0AF68), milestone = c(0x9ECE6A), bad = c(0xF7768E),
            look = c(0x7DCFFF), unseen = c(0xFF9F40), idle = c(0x565F89), live = c(0x61D6AA),
            selection = c(0x24283B), border = c(0x2A2B3C),
            termBg = c(0x1A1B26), termFg = c(0xC0CAF5), termCursor = c(0xC0CAF5),
            ansi = ansiOf(0x1A1D27, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC8CCD6,
                          0x3B4048, 0xFF8DA3, 0xB5E08A, 0xF0C485, 0x9CB8FF, 0xD0B6FF, 0xA0DEFF, 0xE6E8EE))

        private fun dark(id: String, name: String, bg: Long, panel: Long, panelAlt: Long, text: Long,
                         dim: Long, faint: Long, accent: Long, green: Long, blue: Long, yellow: Long,
                         orange: Long, red: Long, cyan: Long, sel: Long, border: Long, cursor: Long,
                         ansi: List<Color>, isLight: Boolean = false) = ThemePalette(
            id, name, isLight,
            bg = c(bg), bgDeep = c(bg), panel = c(panel), panelAlt = c(panelAlt),
            text = c(text), dim = c(dim), faint = c(faint), accent = c(accent),
            working = c(blue), waiting = c(yellow), milestone = c(green), bad = c(red),
            look = c(cyan), unseen = c(orange), idle = c(faint), live = c(green),
            selection = c(sel), border = c(border),
            termBg = c(bg), termFg = c(text), termCursor = c(cursor), ansi = ansi)

        val tokyoNight = dark("tokyonight", "Tokyo Night", 0x24283b, 0x292e42, 0x1f2335, 0xc0caf5,
            0xa9b1d6, 0x565f89, 0x7aa2f7, 0x9ece6a, 0x7aa2f7, 0xe0af68, 0xff9e64, 0xf7768e, 0x7dcfff,
            0x2e3c64, 0x3b4261, 0xc0caf5,
            ansiOf(0x1d202f, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
                   0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5))

        val dracula = dark("dracula", "Dracula", 0x282A36, 0x21222C, 0x343746, 0xF8F8F2,
            0xC8C8DC, 0x6272A4, 0xBD93F9, 0x50FA7B, 0x8BE9FD, 0xF1FA8C, 0xFFB86C, 0xFF5555, 0x8BE9FD,
            0x44475A, 0x44475A, 0xF8F8F2,
            ansiOf(0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                   0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF))

        val catppuccin = dark("catppuccin-mocha", "Catppuccin Mocha", 0x1e1e2e, 0x181825, 0x313244, 0xcdd6f4,
            0xa6adc8, 0x6c7086, 0xcba6f7, 0xa6e3a1, 0x89b4fa, 0xf9e2af, 0xfab387, 0xf38ba8, 0x94e2d5,
            0x45475a, 0x45475a, 0xf5e0dc,
            ansiOf(0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
                   0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8))

        val nord = dark("nord", "Nord", 0x2e3440, 0x272c36, 0x3b4252, 0xd8dee9,
            0xabb2c0, 0x4c566a, 0x88c0d0, 0xa3be8c, 0x81a1c1, 0xebcb8b, 0xd08770, 0xbf616a, 0x88c0d0,
            0x434c5e, 0x434c5e, 0xd8dee9,
            ansiOf(0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                   0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4))

        val gruvbox = dark("gruvbox", "Gruvbox Dark", 0x282828, 0x1d2021, 0x3c3836, 0xebdbb2,
            0xd5c4a1, 0x928374, 0x8ec07c, 0xb8bb26, 0x83a598, 0xfabd2f, 0xfe8019, 0xfb4934, 0x8ec07c,
            0x504945, 0x504945, 0xebdbb2,
            ansiOf(0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
                   0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2))

        val oneDark = dark("one-dark", "One Dark", 0x282c34, 0x21252b, 0x2c313a, 0xabb2bf,
            0x9da5b4, 0x5c6370, 0x61afef, 0x98c379, 0x61afef, 0xe5c07b, 0xd19a66, 0xe06c75, 0x56b6c2,
            0x3e4451, 0x3b4048, 0x61afef,
            ansiOf(0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
                   0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff))

        val solarizedDark = dark("solarized-dark", "Solarized Dark", 0x002b36, 0x073642, 0x073642, 0x839496,
            0x93a1a1, 0x586e75, 0x2aa198, 0x859900, 0x268bd2, 0xb58900, 0xcb4b16, 0xdc322f, 0x2aa198,
            0x073642, 0x586e75, 0x93a1a1,
            ansiOf(0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                   0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3))

        val solarizedLight = dark("solarized-light", "Solarized Light", 0xfdf6e3, 0xeee8d5, 0xeee8d5, 0x657b83,
            0x586e75, 0x93a1a1, 0x2aa198, 0x859900, 0x268bd2, 0xb58900, 0xcb4b16, 0xdc322f, 0x2aa198,
            0xeee8d5, 0x93a1a1, 0x586e75,
            ansiOf(0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                   0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3),
            isLight = true)

        val monokai = dark("monokai", "Monokai", 0x272822, 0x1e1f1a, 0x3e3d32, 0xf8f8f2,
            0xcfcfc2, 0x75715e, 0x66d9ef, 0xa6e22e, 0x66d9ef, 0xe6db74, 0xfd971f, 0xf92672, 0x66d9ef,
            0x49483e, 0x49483e, 0xf8f8f0,
            ansiOf(0x272822, 0xf92672, 0xa6e22e, 0xf4bf75, 0x66d9ef, 0xae81ff, 0xa1efe4, 0xf8f8f2,
                   0x75715e, 0xf92672, 0xa6e22e, 0xe6db74, 0x66d9ef, 0xae81ff, 0xa1efe4, 0xf9f8f5))

        val githubDark = dark("github-dark", "GitHub Dark", 0x0d1117, 0x010409, 0x161b22, 0xc9d1d9,
            0xb1bac4, 0x8b949e, 0x58a6ff, 0x3fb950, 0x58a6ff, 0xd29922, 0xdb6d28, 0xff7b72, 0x39c5cf,
            0x21262d, 0x30363d, 0x58a6ff,
            ansiOf(0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
                   0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xf0f6fc))

        val githubLight = dark("github-light", "GitHub Light", 0xffffff, 0xf6f8fa, 0xf6f8fa, 0x24292f,
            0x57606a, 0x6e7781, 0x0969da, 0x1a7f37, 0x0969da, 0x9a6700, 0xbc4c00, 0xcf222e, 0x1b7c83,
            0xddf4ff, 0xd0d7de, 0x0969da,
            ansiOf(0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
                   0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f),
            isLight = true)

        val rosePine = dark("rose-pine", "Rosé Pine", 0x191724, 0x1f1d2e, 0x26233a, 0xe0def4,
            0x908caa, 0x6e6a86, 0xc4a7e7, 0x9ccfd8, 0x31748f, 0xf6c177, 0xebbcba, 0xeb6f92, 0xebbcba,
            0x403d52, 0x403d52, 0xe0def4,
            ansiOf(0x26233a, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4,
                   0x6e6a86, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4))

        val all = listOf(argus, tokyoNight, dracula, catppuccin, nord, gruvbox, oneDark,
            solarizedDark, solarizedLight, monokai, githubDark, githubLight, rosePine)

        fun byId(id: String) = all.firstOrNull { it.id == id } ?: argus
    }
}

/// The active palette, provided at the root so any composable reads `LocalTheme.current`.
val LocalTheme = staticCompositionLocalOf { ThemePalette.argus }
