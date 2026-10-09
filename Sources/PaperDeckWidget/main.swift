// Entry point of the widget extension. The executable is linked with
// `-e _NSExtensionMain` (ExtensionKit's launcher) AND keeps this Swift `main`,
// which references the bundle so the linker doesn't strip the widget code.
PaperDeckWidgets.main()
