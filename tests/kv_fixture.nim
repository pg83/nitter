# SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, asynchttpserver, httpcore, net, tables, uri]

type KvFixture* = ref object
  server: AsyncHttpServer
  endpoint*: string
  values*: Table[string, string]
  requests*: int
  replyCode*: HttpCode
  delayMs*: int

proc startKvFixture*(): KvFixture =
  let fixture = KvFixture(server: newAsyncHttpServer())
  fixture.server.listen(Port(0), "127.0.0.1")
  fixture.endpoint = "http://127.0.0.1:" & $fixture.server.getPort().int

  proc handler(req: Request) {.async, gcsafe.} =
    inc fixture.requests
    try:
      if fixture.delayMs > 0:
        await sleepAsync(fixture.delayMs)
      if fixture.replyCode.int > 0:
        await req.respond(fixture.replyCode, "unavailable")
        return
      var key: string
      for name, value in decodeQuery(req.url.query):
        if name == "key": key = value
      let path = req.url.path
      if req.reqMethod == HttpPut and path == "/v1/nitter/put":
        fixture.values[key] = req.body
        await req.respond(Http204, "")
      elif req.reqMethod == HttpGet and path == "/v1/nitter/get":
        if key in fixture.values:
          await req.respond(Http200, fixture.values[key])
        else:
          await req.respond(Http404, "")
      else:
        await req.respond(Http404, "")
    except CatchableError:
      discard # A timeout test deliberately closes the client first.

  proc acceptLoop() {.async.} =
    while true:
      try:
        await fixture.server.acceptRequest(handler)
      except CatchableError:
        break
  asyncCheck acceptLoop()
  return fixture

proc close*(fixture: KvFixture) =
  fixture.server.close()
