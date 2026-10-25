# cobble-webbox

Cobblestone's servers on [webbox](https://github.com/showell/zig-webbox): Damian's
server-side Codex compiled to Zig and served by webbox's Linux host, with no QEMU
guest and no PowerShell bridge in front of it.

- **Codex Chat** (`apps/chat`): `ChatServer.codex` and `ChatStore.codex`, a
  chat whose state lives on a FAT16 disk Codex drives itself, on
  http://localhost:9106.
- **Idea Forge** (`apps/ideas`): `IdeaWeb.codex`, a reservation service for
  generated business ideas, on http://localhost:9105.
- **The games** (`apps/games`): `GameServer.codex`, the server side of the 34
  classic games, with Cobblestone's own pages, on http://localhost:9104.

The aim is Damian's server-side Codex running on rented "bare metal": this
Linux host first, then [zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)
on a DigitalOcean droplet, which runs the same webbox sources with no operating
system.

## Running it

From this checkout, beside a Cobblestone checkout at `../cobblestone-pin`
(`COBBLESTONE_ROOT` names another) and `../zig-webbox`, with Zig 0.17:

    zig build serve-chat    # Codex Chat, http://localhost:9106/codex-chat/ (CHAT_PORT), on data/codex-chat.img (CHAT_DISK)
    zig build serve-ideas   # Idea Forge, http://localhost:9105 (IDEAS_PORT)
    zig build serve-uo      # uoaix's live town, http://localhost:9107/uo/town/, and two proofs (UO_PORT)
    zig build serve         # the games, http://localhost:9104 (COBBLE_PORT)
    zig build test

The pages are Cobblestone's own (`apps/games/index.html`, `classic/web/*.html`),
read from the checkout on every request.

## How it fits together

- **`src/chat_app.zig`** is Codex Chat's site, in place of `apps/chat/web/server.ps1`:
  the page (`web/chat.html`: `ChatPage.codex` as the HTML plug builds it, by
  `codex/plugs/html/run.ps1` under QEMU, since the checked-in build threw on load) at
  `/codex-chat/`, and every `/codex-chat/api/chat/*` request to ChatServer's
  `chat-route` (with the prefix taken off), with the time of day and two random
  tokens. Every name it has on a host carries `codex-chat` (paths, bus key, its
  files' folder, the page's localStorage key), so it can share a site with Gopher
  Chat; the page asks for the API relative to itself. `api/chat/events` is an
  event stream (webbox's `sse.forward`): each change publishes `changed`, and
  every open page asks again with its own token. Its state is in files under
  `codex-chat/` in the host's data root (`data/` in a checkout, `CHAT_DATA` for
  another): a file per account (`users/<n>.json`), per conversation
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
  Zig, on a request's 16 MB stack in a host-given region, as tests and as routes:
  `GameVendorReplay` (real buy and sell packets against a vendor; about 75 MB of Codex
  heap) at `/uo/vendor-proof`, and `TownLiveProof` (three residents walking a
  128x224 town to lodging, work and tavern seats; about 24 MB) at `/uo/town-proof`.
  And a live town: `apps/uoaix/TownWatch.codex` (our fork; TownLiveProof's town kept
  between calls) built at start and ticked from `between` every 250 ms at 120 game
  seconds a real one, watched at `/uo/town/` (`web/uo-town.html`, a canvas, over the
  `/uo/town/events` stream). Three game days leave its Codex heap the same as one
  (about 18 MB). Up to five players join (`/uo/town/join`), walk where they tap
  (`/uo/town/go`, by the townsfolk's own routes), are greeted by the residents and
  keepers, talk to them (`/uo/town/say`) and buy from a keeper (`/uo/town/offers`,
  `/uo/town/buy`): only the first player's purse holds coin. The UO server itself does not run here yet.
- A panic in one request ends the process.
- The emitted runtime reserves its heap from the OS (4 GiB of address space, taken
  lazily) and never frees it: fine for a dev port, not yet for a 512 MB droplet.
