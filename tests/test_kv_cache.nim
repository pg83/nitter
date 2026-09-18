# SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, httpcore, monotimes, options, tables, times, unittest]
import ../src/kv_cache
import kv_fixture

suite "KV HTTP cache":
  setup:
    let fixture = startKvFixture()
    let cache = initKvCache(fixture.endpoint, "nitter")
  teardown:
    cache.close()
    fixture.close()

  test "miss, empty and binary values, and escaped keys":
    check (waitFor cache.get("missing")).isNone
    for value in ["", "\x00\xff\n", "hello"]:
      waitFor cache.put("ключ /?&=+", value)
      check (waitFor cache.get("ключ /?&=+")) == some(value)
    check fixture.values.len == 1
    check fixture.values.hasKey("nitter:v1:ключ /?&=+")

  test "absolute expiry is shared and reads do not extend it":
    let other = initKvCache(fixture.endpoint, "nitter")
    defer: other.close()
    waitFor cache.put("ttl", "value", ttl=10, now=100)
    check (waitFor other.get("ttl", now=109)) == some("value")
    check (waitFor cache.get("ttl", now=110)).isNone
    check (waitFor other.get("ttl", now=111)).isNone

  test "overwrite resets the deadline and negative TTL does not expire":
    waitFor cache.put("ttl", "old", ttl=10, now=100)
    waitFor cache.put("ttl", "new", ttl=10, now=109)
    check (waitFor cache.get("ttl", now=110)) == some("new")
    check (waitFor cache.get("ttl", now=119)).isNone
    waitFor cache.put("forever", "id", now=100)
    check (waitFor cache.get("forever", now=1_000_000)) == some("id")

  test "zero TTL and disabled cache do not send requests":
    waitFor cache.put("zero", "value", ttl=0)
    let disabled = initKvCache(fixture.endpoint, "nitter", enabled=false)
    defer: disabled.close()
    waitFor disabled.put("disabled", "value")
    check (waitFor disabled.get("disabled")).isNone
    check fixture.requests == 0

  test "namespace isolates clients":
    let other = initKvCache(fixture.endpoint, "nitter", prefix="other:")
    defer: other.close()
    waitFor cache.put("same", "first")
    waitFor other.put("same", "second")
    check (waitFor cache.get("same")) == some("first")
    check (waitFor other.get("same")) == some("second")

  test "malformed and unsupported envelopes are misses":
    for value in ["", "old", "NK2\n-1\ndata", "NK1\n", "NK1\nnot-a-time\nx",
                  "NK1\n-2\nx", "NK1\n99999999999999999999999999999999\nx"]:
      fixture.values["nitter:v1:bad"] = value
      check (waitFor cache.get("bad")).isNone

  test "HTTP failures are misses and failed writes are harmless":
    for code in [Http400, Http413, Http500, Http503, Http302]:
      fixture.replyCode = code
      check (waitFor cache.get("bad")).isNone
      waitFor cache.put("bad", "value")
    fixture.replyCode = HttpCode(0)
    waitFor cache.put("recovered", "yes")
    check (waitFor cache.get("recovered")) == some("yes")

  test "deadline bounds slow requests and the client recovers":
    let impatient = initKvCache(fixture.endpoint, "nitter", timeoutMs=30)
    defer: impatient.close()
    fixture.delayMs = 250
    let started = getMonoTime()
    check (waitFor impatient.get("slow")).isNone
    check (getMonoTime() - started).inMilliseconds < 200
    fixture.delayMs = 0
    waitFor impatient.put("recovered", "yes")
    check (waitFor impatient.get("recovered")) == some("yes")
    waitFor sleepAsync(260)

  test "concurrent operations have independent HTTP connections":
    var writes: seq[Future[void]]
    for i in 0..<40:
      writes.add cache.put($i, "value-" & $i)
    waitFor all(writes)
    var reads: seq[Future[Option[string]]]
    for i in 0..<40:
      reads.add cache.get($i)
    let results = waitFor all(reads)
    for i, value in results:
      check value == some("value-" & $i)

  test "invalid configuration fails at startup":
    for endpoint in ["", "ftp://localhost", "http://", "http://localhost/path",
                     "http://u:p@localhost", "http://localhost?x=y", "http://localhost#f"]:
      expect ValueError:
        discard initKvCache(endpoint, "nitter")
    for bucket in ["", "a/b", "a?b", "a#b"]:
      expect ValueError:
        discard initKvCache(fixture.endpoint, bucket)
    expect ValueError:
      discard initKvCache(fixture.endpoint, "nitter", timeoutMs=0)
