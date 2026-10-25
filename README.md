# cobble-webbox

Cobblestone's servers on [webbox](https://github.com/showell/zig-webbox): Damian's
server-side Codex compiled to Zig and served by webbox's Linux host, with no QEMU
guest and no PowerShell bridge in front of it.

- **Codex Chat** (`apps/chat`): `ChatServer.codex` and `ChatStore.codex`, a
  chat whose state is files Codex keeps through its FileSystem effect.
  Standalone on http://localhost:9106/; mounted in Gopher Chat at
  `/codex-chat/`.
- **The UO town** (`apps/uoaix/TownWatch.codex`): Damian's uoaix townsfolk,
  shops and trade, kept and ticked live, joinable by up to five players; a
  demo of the uoaix shard's code, not the UO server. Standalone on
  http://localhost:9107/town/; mounted in Gopher Chat at `/uo/town/`.
- **Idea Forge** (`apps/ideas`): `IdeaWeb.codex`, a reservation service for
  generated business ideas, on http://localhost:9105. Standalone only.
- **The games** (`apps/games`): `GameServer.codex`, the server side of the 34
  classic games, with Cobblestone's own pages, on http://localhost:9104.
  Standalone only.

The aim is Damian's server-side Codex running on rented "bare metal": this
Linux host first, then [zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)
on a DigitalOcean droplet, which runs the same webbox sources with no operating
system.

## From a clone to a running app

**Sibling checkouts** (paths are fixed in `build.zig.zon` and `build.zig`):

- `../zig-webbox` — the library (`build.zig.zon`'s `webbox` path dependency).
- `../cobblestone-pin` — our Cobblestone fork on its `webbox` branch (here a
  worktree of `~/showell_repos/NewRepository`, remote
  `showell/NewRepository`; upstream `damiant3/Cobblestone`). `zig build test`
  embeds the uoaix proofs' `.expected` files from it, and `serve` reads the
  games' pages from it at run time (`COBBLESTONE_ROOT` names another for
  `serve` only). `serve-chat`, `serve-uo` and `serve-ideas` do not read it:
  `src/gen/` and `web/` are checked in.

**Zig 0.17** (`build.zig.zon`'s `minimum_zig_version`). Then, from this checkout:

    zig build test          # the sites' tests and the libraries' answers (build.zig's `test` step)
    zig build serve-chat    # Codex Chat, http://localhost:9106/
    zig build serve-uo      # the UO town, http://localhost:9107/town/
    zig build serve-ideas   # Idea Forge, http://localhost:9105/
    zig build serve         # the games, http://localhost:9104/

`zig build -l` lists the steps. Each server's Linux host reads
`<APP>_PORT`, `<APP>_BIND`, `<APP>_CONFIG`, `<APP>_TRUSTED_PROXY` and
`<APP>_KEEPALIVE_MS`, with `<APP>` one of `CHAT`, `UO`, `IDEAS`, `COBBLE`
(`src/*main.zig`), and opens `auth/` beside `data/` (both gitignored).
Codex Chat keeps its files in `data/codex-chat/` (`CHAT_DATA` names another);
the others keep nothing on disk. The games' pages are Cobblestone's own
(`apps/games/index.html`, `classic/web/*.html`), read on every request.

Pitfall: Codex Chat refuses to start on files it cannot trust (a missing
account file, one that does not parse) and says which; the UO town stops if
its first tick fails. Both print why and exit 1 (`src/chat_main.zig`,
`src/uo_main.zig`).

## Regenerating `src/gen/`

`src/gen/*.zig` is generated (each file's header says from which Codex root
and at which Cobblestone commit); never edit it. To change a Codex app, change
it in the fork, commit there, then:

    cd ~/showell_repos/cobble-webbox && shale tools/regen.shale

It needs [Shale](https://github.com/showell/shale) with these mounts (or the
script's `NAME=VALUE` overrides, `tools/regen.shale`'s `arg(...)` lines):
`cobble:` the fork checkout, `repos:` holding `codex-zig-transpiler`,
`zig016:` a Zig 0.16 install, and PowerShell at `~/.local/pwsh/pwsh` (the
fork's bundler, `build/bundle-app.ps1`, is PowerShell). The first run builds
codexzig into `.zig-cache/` (about 2 min). If regen stops with "no library
face", the transpiler's checked-in codexzig lacks the fork's library mode:
run `shale tools/codexzig.shale` (rebuilds codexzig from the fork) and regen
again. Then `zig build test`, and commit `src/gen/` with the change.

`web/chat.html` and `web/idea-forge.html` are Cobblestone's HTML plug's
output, built by hand under QEMU (see `web/idea-forge.html` below);
`web/uo-town.html` is hand-written; `tools/compiler.shale` builds Damian's
compiler from the fork for testing compiler or foreword changes on bare metal.

## Mounted in another site, and deployed

`build.zig` exports two modules for a site that serves them among its own
routes with webbox's combo (`webbox.combo.Mount`, `../zig-webbox/src/combo.zig`):

- `codex_chat` — `src/chat_app.zig`, with `web/chat.html` compiled in.
- `uo_town` — `src/uo_app.zig`, with `web/uo-town.html` compiled in.

**The mount contract.** Each answers every path from `/`; the combo strips
its prefix, sends the bare prefix to `prefix/`, and gives the mount
`<data>/<name>` and `<auth>/<name>` (the name is the prefix's segment). So the
app's pages ask for everything relative to themselves, never `/...`; its
event-stream bus key carries its own name (`codex-chat`, `uo-town`); its
setup takes its folder from `roots` and falls back to a checkout default only
when run alone; and it exports `hosting` (`data_name`, `describeStart`) for
the combined site's start log. Idea Forge and the games use absolute paths
(`/offer`, `/api/...`, `/games/...`) and are not mountable as they stand.

**Where they run.** [angry-gopher](https://github.com/showell/angry-gopher)
(Gopher Chat) is the primary: `zig-server/src/router.zig` mounts `codex_chat`
at `/codex-chat` and `uo_town` at `/uo`, through `zig-server/build.zig.zon`'s
path dependency on this checkout (`../../cobble-webbox`). A combination is
built and tested in the primary's repo, not here. Codex Chat's files there are
`data/codex-chat/`. lynrummy.com itself is served by zig-metal-unikernel,
whose `build.zig` makes the same two modules from this checkout's sources
(`-Dcobble-root=` names another; default `../cobble-webbox`) with its own
`host_io`; a change here reaches the site only as a new kernel release, by
that repo's `DEPLOY.md` (what serves is its newest `v*` tag, so whether
lynrummy.com carries a given change here is that tag's question).

## How it fits together

- **`src/chat_app.zig`** is Codex Chat's site, in place of `apps/chat/web/server.ps1`:
  the page (`web/chat.html`: `ChatPage.codex` as the HTML plug builds it, by
  `codex/plugs/html/run.ps1` under QEMU, since the checked-in build threw on load) at
  `/`, and every `/api/chat/*` request to ChatServer's `chat-route`, with the
  time of day and two random tokens. Its bus key and the page's localStorage
  key carry `codex-chat`, so it can share a site with Gopher Chat; the page
  asks for the API relative to itself. `api/chat/events` is an
  event stream (webbox's `sse.forward`): each change publishes `changed`, and
  every open page asks again with its own token. Its state is in files in the
  folder the host gives it (`data/codex-chat/` alone or mounted at
  `/codex-chat`; `CHAT_DATA` for another), onto which `chat_files.zig` maps
  ChatStore's own `codex-chat/`: a file per account (`users/<n>.json`), per conversation
  (`convs/<id>/conv.json`), and each conversation's messages, a line each
  (`convs/<id>/messages.jsonl`). ChatStore keeps them through Codex's FileSystem
  effect, whose ops the ZigEmitter turns into calls on the program's host, here
  **`src/chat_files.zig`** over webbox's store (FAT's rules on every host, and
  on a droplet the attached volume, beside Gopher Chat's `chat/`). It reads them
  at the start; after every request that changes anything it writes only what
  that request added, a message by appending it. Files it cannot trust with the
  next write (a missing account file, one that does not parse) are not served.
  ChatServer and ChatStore are new Codex, on our fork's `webbox` branch:
  Cobblestone's ChatServer was a stub, and server.ps1 the real server.

- **`src/uo_app.zig`** is the UO town's site: TownWatch's library
  (`src/gen/uo_watch.zig`, through `src/uo_watch_api.zig`) built at setup on a
  128 MB Codex heap region and ticked from `between`; its routes, all under
  `town/`, are listed at the top of the file. The page is `web/uo-town.html`
  (hand-written, not the HTML plug's). Its state is in memory: a restart is a
  new town. `src/uo_test.zig` also runs two of uoaix's proofs
  (`src/gen/uo.zig`, `uo_town.zig`) against their `.expected` output.

- **`src/ideas_app.zig`** is Idea Forge's site: `apps/ideas/IdeaServer.codex`'s
  network shell and `run.ps1`'s bridge, replaced. Every request goes to
  IdeaWeb's `idea-route-at`, with the two facts IdeaServer supplied: the caller
  (`X-Forwarded-For`, else `?who=`, else `the-proxy`, as `resolve-who` has it:
  any proxy's word is believed, as there) and the day (whole days since the
  house opened, as `current-day` counts PIT ticks since boot). Its state is in
  memory, as there. Its page is served at `/`, as run.ps1 served it.
- **`web/idea-forge.html`** is that page: `apps/ideas/IdeaPage.codex` (a widget
  tree) as Cobblestone's HTML plug built it, once, by Damian's own scripts under
  QEMU (no codex-vm here; his vm-config.ps1 falls back to it), at c660bb418813:

      pwsh codex/plugs/html/build.ps1
      pwsh codex/plugs/html/run.ps1 -Src apps/ideas/IdeaPage.codex -Out <this repo>/web/idea-forge.html

  About 20 s in all. It is checked in because it is built rarely and by a guest;
  `build.zig` compiles it into the server.

- **`src/app.zig`** is the site: Cobblestone's `apps/games/server.ps1`, route for
  route. `/api/*` hands GameServer the line server.ps1 built (`GET /api/tictactoe/step`)
  and answers with the line GameServer prints (`200 application/json {...}`), as
  server.ps1 did over the game VM's serial port. The store GameServer threads from
  request to request lives in the site.
- **`src/gen/games.zig`** is generated: GameServer.codex and the 42 chapters it
  cites, transpiled by codexzig (from
  [codex-zig-transpiler](https://github.com/showell/codex-zig-transpiler)) in the
  ZigEmitter's library mode (our fork): **`tools/regen.shale`** bundles each
  application and declares its exports (`zig-library`), and the library has no
  `main`, its exports `pub`, and a `cx` face for the heap the host gives and for
  text across the edge. Each `src/*_api.zig` wraps a library for its site
  (`os_heap.zig` gives the Linux-only ones their heap). `src/gen/ideas.zig`,
  `chat.zig` and `uo*.zig` are the same for their chapters.
- **`tools/codexzig.shale`** rebuilds codexzig natively from the Cobblestone
  checkout, so an emitter change needs no QEMU: three passes, and the third must
  equal the second byte for byte.

## Cobblestone changes, carried in our fork

Work happens on the `webbox` branch of our Cobblestone fork (in the
`../cobblestone-pin` worktree), on top of upstream's Update 70. What a Codex
default already does as well as webbox would, webbox's side matches; a real
opinion goes to Cobblestone as a pull request, and lives on the branch until it
is merged.

- ZigEmitter: three forms Zig 0.17 refuses, rewritten in forms 0.16 and 0.17 both
  take (b8b4f722); and the block device and process scope (`block-read-sector`,
  `block-write-sector`, `process-get-scope`) as calls into the program's host,
  so the Fat16 foreword runs on a host's disk.
- Codex Chat's server and its store on disk: `apps/chat/ChatServer.codex` (the
  routes server.ps1 served) and `ChatStore.codex` (the files above, on the FAT16
  boot volume), with `codex/test/apps/chat-server` and `chat-store`. Both answer
  the same on bare metal under QEMU, where chat-store, booted twice on one disk,
  finds the first boot's state and appends to it. `ChatServe.codex` serves it on
  bare metal (WebServer's concurrent loop, with the same event stream), and
  ChatPage listens to the stream (`event-source-then`, a new HTML plug primitive).
- ZigEmitter: a library mode (`zig-library : Text = "|a|b|"`, which the build adds:
  the exports `pub` and the prune's roots, no `main`, a `cx` face), and the
  prune roots a chapter with no `opening` at its exports.
- ZigEmitter: `poke-qword` and `peek-16` (built from `poke-32` and `peek-byte`, taking no
  prelude part: the table is at 127 of 128), the PIT constants `pit-input-hz` and `pit-count`, and closures of
  arity 6, which uoaix's proofs need.
- Fat16: `fat16-append-file`, which writes only the new bytes
  (`codex/test/fat16-append`).
- FileSystem: `append-file`, `list-dir` and `make-dir`, with default handlers on
  x86 and their scope rows in the type checker (`codex/test/fs-ops`,
  `codex/test/errors/fs-ops-computed-scope`); and the ZigEmitter turns all five
  FileSystem ops into calls on the program's host (`cx_file_host`). Tested with
  a compiler built from the fork by the seed under QEMU: **`tools/compiler.shale`**
  (about 100 s; Damian's `concat-codex-self.ps1` spells paths with backslashes,
  so the recipe runs a corrected copy).
- GameServer: a new Yahtzee game's dice sent as they are ([#160](https://github.com/damiant3/Cobblestone/pull/160)),
  and Spider's suggested move decoded with `sp-decode-move` ([#161](https://github.com/damiant3/Cobblestone/pull/161)).
  Each trapped on an out-of-bounds `list-at`, on bare metal as in Zig: behind
  server.ps1, a 504 and a VM restart.

## Status (2026-10-24)

- All 33 of GameServer's game routes (all but `/api/run/`) answer `new` and their
  first steps through the emitted Zig, with the two GameServer fixes above.
- Idea Forge answers its whole protocol: a deal of three, the second deal of the
  day refused (429), a claim, a foreign claim refused (404), the ledger with its
  holder masked, window shopping.
- Two of uoaix's proofs print their expected lines byte for byte through the emitted
  Zig, on a request's 16 MB stack in a host-given region:
  `GameVendorReplay` (real buy and sell packets against a vendor; about 75 MB of Codex
  heap) and `TownLiveProof` (three residents walking a 128x224 town to lodging, work and
  tavern seats; about 24 MB), as tests.
  And a live town, paused until a watcher starts its day: `apps/uoaix/TownWatch.codex` (our fork; TownLiveProof's town kept
  between calls) built at start and ticked from `between` every 250 ms at 120 game
  seconds a real one, watched at `town/` (`/uo/town/` in Gopher Chat; `web/uo-town.html`, a canvas, over the
  `town/events` stream). Three game days leave its Codex heap the same as one
  (about 18 MB). Up to five players join (`town/join`), walk where they tap
  (`town/go`, by the townsfolk's own routes), are greeted by the residents and
  keepers, talk to them (`town/say`) and buy from a keeper (`town/offers`,
  `town/buy`; only the first player's purse holds coin), and send a resident
  home, to work or to the tavern for a game hour (`town/errand`). The UO server itself does not run here yet.
- A panic in one request ends the process.
- The emitted runtime reserves its heap from the OS (4 GiB of address space, taken
  lazily) and never frees it: fine for a dev port, not yet for a 512 MB droplet.
