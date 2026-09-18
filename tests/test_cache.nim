# SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, os, times, unittest, strutils]
import ../src/[cache, config, types]
import kv_fixture

let fixture = startKvFixture()
let endpoints = getEnv("KV_TEST_ENDPOINTS", fixture.endpoint).split(',')
var namespace, clientNumber = 0
proc cacheConfig(enabled=true; rss=1; lists=1): Config =
  inc clientNumber
  Config(cacheEnabled: enabled, kvEndpoint: endpoints[clientNumber mod endpoints.len], kvBucket: "nitter",
         kvPrefix: "test:" & $getCurrentProcessId() & ":" & $namespace & ":",
         kvTimeoutMs: 1000, rssCacheTime: rss, listCacheTime: lists)

suite "application cache backed by KV":
  setup:
    inc namespace
    initCache(cacheConfig())
    let joined = fromUnix(1600000000).utc

  test "example configuration uses the local KV front":
    let (cfg, _) = getConfig(currentSourcePath.parentDir.parentDir / "nitter.example.conf")
    check cfg.cacheEnabled
    check cfg.kvEndpoint == "http://127.0.0.1:8061"
    check cfg.kvBucket == "nitter"
    check cfg.kvTimeoutMs == 1000

  test "profiles and ID mappings normalize usernames":
    waitFor cache(User(id: "123", username: "Alice", fullname: "Alice", joinDate: joined))
    let user = waitFor getCachedUser("ALICE", fetch=false)
    check user.fullname == "Alice"
    check user.joinDate == joined
    check (waitFor getUserId("aLiCe")) == "123"
    check (waitFor getCachedUser("missing", fetch=false)).id == ""

  test "account info is cached separately from the profile":
    waitFor cache(User(id: "123", username: "alice", fullname: "Alice", joinDate: joined))
    waitFor cache(AccountInfo(basedIn: "France", joinDate: joined,
                             lastUsernameChange: joined, verifiedSince: joined), "Alice")
    check (waitFor getCachedAccountInfo("ALICE", fetch=false)).basedIn == "France"
    check (waitFor getCachedUser("alice", fetch=false)).fullname == "Alice"

  test "lists and communities retain independent namespaces":
    waitFor cache(List(id: "123", name: "List"))
    waitFor cache(Community(id: "123", name: "Community", createdAt: joined,
                           creator: User(joinDate: joined)))
    check (waitFor getCachedList(id="123")).name == "List"
    check (waitFor getCachedCommunity("123")).name == "Community"

  test "photo rails are snapshots and empty results are cache hits":
    var rail: PhotoRail = @[GalleryPhoto(url: "original")]
    waitFor cache(rail, "123")
    rail[0].url = "changed"
    var restored = waitFor getCachedPhotoRail("123")
    check restored[0].url == "original"
    restored[0].url = "changed again"
    check (waitFor getCachedPhotoRail("123"))[0].url == "original"
    waitFor cache(PhotoRail(@[]), "456")
    check (waitFor getCachedPhotoRail("456")).len == 0

  test "RSS stores the cursor and feed together":
    waitFor cacheRss("feed", Rss(cursor: "cursor-1", feed: "<rss>one</rss>"))
    check (waitFor getCachedRss("feed")) == Rss(cursor: "cursor-1", feed: "<rss>one</rss>")
    waitFor cacheRss("feed", Rss(cursor: "cursor-2", feed: "<rss>two</rss>"))
    check (waitFor getCachedRss("feed")) == Rss(cursor: "cursor-2", feed: "<rss>two</rss>")
    check (waitFor getCachedRss("missing")) == Rss()

  test "suspended RSS entries do not retain an old feed":
    waitFor cacheRss("feed", Rss(cursor: "cursor-1", feed: "<rss/>"))
    waitFor cacheRss("feed", Rss(cursor: "suspended", feed: "alice"))
    check (waitFor getCachedRss("feed")) == Rss(cursor: "suspended")
    waitFor cacheRss("empty", Rss(cursor: "", feed: "<rss/>"))
    check (waitFor getCachedRss("empty")) == Rss()

  test "disabled cache bypasses existing shared data":
    waitFor cacheRss("feed", Rss(cursor: "cursor-1", feed: "<rss/>"))
    initCache(cacheConfig(enabled=false))
    waitFor cache(User(id: "123", username: "alice", joinDate: joined))
    check (waitFor getCachedUser("alice", fetch=false)).id == ""
    check (waitFor getCachedRss("feed")) == Rss()

  test "zero RSS lifetime disables RSS caching":
    waitFor cacheRss("feed", Rss(cursor: "old-cursor", feed: "old"))
    initCache(cacheConfig(rss=0))
    waitFor cacheRss("feed", Rss(cursor: "cursor-1", feed: "<rss/>"))
    check (waitFor getCachedRss("feed")) == Rss()

  test "zero list lifetime skips writes":
    initCache(cacheConfig(lists=0))
    waitFor cacheRss("feed", Rss(cursor: "cursor-1", feed: "<rss/>"))
    waitFor cache(List(id: "123", name: "List"))
    check (waitFor getCachedRss("feed")).feed == "<rss/>"

  test "new clients retain cached data across reinitialization":
    waitFor cacheRss("feed", Rss(cursor: "cursor-1", feed: "<rss/>"))
    initCache(cacheConfig())
    check (waitFor getCachedRss("feed")).feed == "<rss/>"

fixture.close()
