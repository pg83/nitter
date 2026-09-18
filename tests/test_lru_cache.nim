# SPDX-License-Identifier: AGPL-3.0-only
import std/[monotimes, options, times, unittest]
import ../src/lru_cache

suite "in-memory LRU cache":
  test "missing, empty and binary values are distinct":
    var cache = initLruCache(2)
    check cache.get("missing").isNone
    cache.put("empty", "")
    cache.put("binary", "\0\0\xff")
    check cache.get("empty") == some("")
    check cache.get("binary") == some("\0\0\xff")

  test "reads promote entries and evict the least recently used":
    var cache = initLruCache(2)
    cache.put("a", "A")
    cache.put("b", "B")
    check cache.get("a") == some("A")
    cache.put("c", "C")
    check cache.len == 2
    check cache.get("b").isNone
    check cache.get("a") == some("A")
    check cache.get("c") == some("C")

  test "overwriting promotes an entry without evicting another":
    var cache = initLruCache(2)
    cache.put("a", "old")
    cache.put("b", "B")
    cache.put("a", "new")
    check cache.len == 2
    cache.put("c", "C")
    check cache.get("b").isNone
    check cache.get("a") == some("new")

  test "TTL expires at its deadline and is not extended by reads":
    var cache = initLruCache(2)
    let start = getMonoTime()
    cache.put("a", "A", ttl=10, now=start)
    check cache.get("a", start + initDuration(seconds=9)) == some("A")
    check cache.get("a", start + initDuration(seconds=10)).isNone
    check cache.len == 0

  test "overwriting refreshes the TTL":
    var cache = initLruCache(2)
    let start = getMonoTime()
    cache.put("a", "old", ttl=10, now=start)
    cache.put("a", "new", ttl=10, now=start + initDuration(seconds=9))
    check cache.get("a", start + initDuration(seconds=10)) == some("new")
    check cache.get("a", start + initDuration(seconds=19)).isNone

  test "expiration can remove the head, middle or tail":
    let start = getMonoTime()
    for expired in ["a", "b", "c"]:
      var cache = initLruCache(3)
      for key in ["a", "b", "c"]:
        cache.put(key, key, ttl=(if key == expired: 1 else: -1), now=start)
      check cache.get(expired, start + initDuration(seconds=1)).isNone
      check cache.len == 2
      cache.put("d", "d")
      check cache.len == 3
      for key in ["a", "b", "c", "d"]:
        if key != expired:
          check cache.get(key) == some(key)

  test "entries without TTL are still subject to eviction":
    var cache = initLruCache(1)
    let start = getMonoTime()
    cache.put("a", "A", now=start)
    check cache.get("a", start + initDuration(days=365)) == some("A")
    cache.put("b", "B")
    check cache.get("a").isNone
    check cache.get("b") == some("B")

  test "zero TTL removes an existing value":
    var cache = initLruCache(2)
    cache.put("a", "A")
    cache.put("a", "discarded", ttl=0)
    cache.put("b", "discarded", ttl=0)
    check cache.len == 0
    check cache.get("a").isNone
    check cache.get("b").isNone

  test "nonpositive capacity disables the cache":
    for capacity in [0, -1]:
      var cache = initLruCache(capacity)
      cache.put("a", "A")
      check cache.len == 0
      check cache.get("a").isNone

  test "repeated eviction remains bounded and preserves the hot entry":
    var cache = initLruCache(3)
    cache.put("hot", "H")
    for i in 0 ..< 1000:
      cache.put($i, $i)
      check cache.len <= 3
      check cache.get("hot") == some("H")
      check cache.get($i) == some($i)
      if i >= 2:
        check cache.get($(i - 2)).isNone
