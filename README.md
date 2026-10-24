# cobble-webbox

Cobblestone's game server on [webbox](https://github.com/showell/zig-webbox).
Damian's `apps/games/GameServer.codex`, the server side of the 34 classic games,
compiled from Codex to Zig and served by webbox's Linux host, with no QEMU guest
and no PowerShell bridge between the pages and the games.

The aim is Damian's server-side Codex running on rented "bare metal": this
Linux host first, then [zig-metal-unikernel](https://github.com/showell/zig-metal-unikernel)
on a DigitalOcean droplet, which runs the same webbox sources with no operating
system.

## Running it

From this checkout, beside a Cobblestone checkout at `../cobblestone-pin`
(`COBBLESTONE_ROOT` names another) and `../zig-webbox`, with Zig 0.17:

    zig build serve     # http://localhost:9104 (COBBLE_PORT)
    zig build test

The pages are Cobblestone's own (`apps/games/index.html`, `classic/web/*.html`),
read from the checkout on every request.

## How it fits together

- **`src/app.zig`** is the site: Cobblestone's `apps/games/server.ps1`, route for
  route. `/api/*` hands GameServer the line server.ps1 built (`GET /api/tictactoe/step`)
  and answers with the line GameServer prints (`200 application/json {...}`), as
  server.ps1 did over the game VM's serial port. The store GameServer threads from
  request to request lives in the site.
- **`src/gen/games.zig`** is generated: GameServer.codex and the 42 chapters it
  cites, transpiled by codexzig (from
  [codex-zig-transpiler](https://github.com/showell/codex-zig-transpiler)), then
  reshaped into a library by **`tools/regen.shale`**: no `main`, Console output
  through a host's hook, and the face in **`src/games_api.zig.in`** appended. That
  script is the ZigEmitter's library mode until the emitter has one.
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
  take (b8b4f722).
- GameServer: a new Yahtzee game's dice sent as they are ([#160](https://github.com/damiant3/Cobblestone/pull/160)),
  and Spider's suggested move decoded with `sp-decode-move` ([#161](https://github.com/damiant3/Cobblestone/pull/161)).
  Each trapped on an out-of-bounds `list-at`, on bare metal as in Zig: behind
  server.ps1, a 504 and a VM restart.

## Status (2026-10-24)

- All 33 of GameServer's game routes (all but `/api/run/`) answer `new` and their
  first steps through the emitted Zig, with the two GameServer fixes above.
- A panic in one game ends the process for all of them.
- The emitted runtime reserves its heap from the OS (4 GiB of address space, taken
  lazily) and never frees it: fine for a dev port, not yet for a 512 MB droplet.
