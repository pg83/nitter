# SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, os, times]
import ../src/[cache, types]

initCache(Config(cacheEnabled: true, kvEndpoint: getEnv("KV_TEST_ENDPOINT"),
                 kvBucket: "nitter", kvPrefix: "process-test:v1:",
                 kvTimeoutMs: 1000, rssCacheTime: 1, listCacheTime: 1))
let user = User(id: "42", username: "Alice", fullname: "Shared profile",
                joinDate: fromUnix(1600000000).utc)
let rss = Rss(cursor: "next-cursor", feed: "<rss>shared\x00data</rss>")
if paramStr(1) == "write":
  waitFor cache(user)
  waitFor cacheRss("feed", rss)
else:
  doAssert (waitFor getCachedUser("ALICE", fetch=false)).fullname == user.fullname
  doAssert (waitFor getUserId("Alice")) == "42"
  doAssert (waitFor getCachedRss("feed")) == rss
echo "shared cache process ", paramStr(1), ": OK"
