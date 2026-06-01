import CoreText
import SwiftUI

// Register bundled fonts (MesloLGS NF) so the terminal can render powerline /
// Nerd-Font glyphs that the system monospace font lacks (otherwise: tofu boxes).
for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}

// Entry point. (No @main so we can keep this file named main.swift; the App
// protocol supplies a static main() that boots the SwiftUI lifecycle.)
UniversalTmuxApp.main()
