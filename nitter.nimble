# Package

version       = "0.1.0"
author        = "zedeus"
description   = "An alternative front-end for Twitter"
license       = "AGPL-3.0"
srcDir        = "src"
bin           = @["nitter"]


# Dependencies

requires "nim >= 2.0.0"
requires "jester == 0.6.0"
requires "karax == 1.5.0"
requires "sass == 0.2.0"
requires "nimcrypto == 0.7.3"
requires "markdown == 0.8.8"
requires "packedjson#9e6fbb6"
requires "supersnappy == 2.1.4"
requires "zippy == 0.10.19"
requires "flatty == 0.4.0"
requires "jsony == 1.1.6"
requires "oauth == 0.11"

# Tasks

task testCache, "Test the KV client and shared application cache":
  exec "nim r --mm:refc --assertions:on tests/test_kv_cache.nim"
  exec "nim r --mm:refc --assertions:on tests/test_cache.nim"

task testKv, "Test separate Nitter processes against KV 2 (KV_BIN required)":
  exec "nim c --mm:refc --assertions:on tests/test_cache.nim"
  exec "nim c --mm:refc --assertions:on tests/cache_probe.nim"
  exec "python3 tests/kv_integration.py --kv \"$KV_BIN\""

task scss, "Generate css":
  exec "nim r --hint[Processing]:off tools/gencss"

task md, "Render md":
  exec "nim r --hint[Processing]:off tools/rendermd"
