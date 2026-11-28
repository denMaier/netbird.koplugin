std = "luajit"
self = false
-- Translatable strings stay whole, so translators see them in one piece.
max_line_length = false
-- Placeholders for values we don't use: _exit, _url, loop indexes (_i).
unused_secondaries = false
ignore = { "21[13]/_.*" }
globals = { "G_reader_settings" }
exclude_files = { "test/emulator/out/**" }
