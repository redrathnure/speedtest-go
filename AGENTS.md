# AGENTS.md

Guidelines for AI agents and contributors working in this repository.

## Project overview

speedtest-go is the Go implementation of LibreSpeed: a self-hosted speed test
server. A single Go binary serves a static JavaScript front end (download /
upload / ping / jitter tests run in the browser via XHR + Web Workers), records
optional telemetry into one of several pluggable databases, and renders result
PNGs, JSON APIs and a password-gated stats page.

- Language/runtime: Go (see `go.mod` for the exact version; 1.25 currently)
- Web framework: [go-chi/chi v5](https://github.com/go-chi/chi) + `net/http`
- Config: [spf13/viper](https://github.com/spf13/viper) reading `settings.toml`
- Logging: [sirupsen/logrus](https://github.com/sirupsen/logrus), always
  imported as `log "github.com/sirupsen/logrus"`
- Front end: plain vanilla JS/HTML/CSS — **no build step, no npm, no bundler**

## Commands

```sh
# Build (release flags used by CI and docs)
go build -ldflags "-w -s" -trimpath -o speedtest .

# Run locally (reads ./settings.toml, or -c <path>)
go run . -c settings.toml

# Tests (table-driven; currently only results/telemetry_test.go)
go test ./...

# Format + static checks — run before committing
gofmt -w <changed files>   # or: gofmt -l .   to list unformatted files
go vet ./...

# Debian package
./deb/build.sh   # builds deb/build/speedtest-go_<version>_<arch>.deb
sh -n deb/build.sh deb/DEBIAN/postinst deb/DEBIAN/prerm deb/DEBIAN/postrm
systemd-analyze verify deb/speedtest-go.service
```

Notes:

- `CGO_ENABLED=0` is assumed by the Dockerfile and `.goreleaser.yml`; keep the
  codebase free of CGO dependencies (the SQLite driver is pure Go:
  `modernc.org/sqlite`).
- The Go image version (`golang:1.25-alpine` in the `Dockerfile` and
  `Dockerfile.build`) must stay in sync with the `go` directive in `go.mod`
  — bump both together whenever the toolchain requirement changes.
- Releases are cut with GoReleaser v2 (`.goreleaser.yml`) from the `master`
  branch via the manual `release.yml` workflow. Docker images are built
  multi-arch by `docker-publish.yml`.
- There is no linter config (no golangci-lint, no eslint/prettier). Match the
  surrounding code instead.

## Project structure

```
main.go                 Entry point: parse -c flag, load config, init
                        results/database/web, start HTTP server.
config/config.go        Config struct (mapstructure tags) + viper loading,
                        env override with SPEEDTEST_ prefix, defaults.
web/
  web.go                chi router: all routes, CORS, asset serving
                        (//go:embed assets fallback when assets_path is
                        missing), PHP-compatible .php endpoint aliases.
  listener.go           startListener for non-linux (TLS/HTTP2).
  listener_linux.go     startListener for linux (systemd socket activation).
  helpers.go            IP/ISP lookup (ipinfo.io + GeoIP .mmdb fallback),
                        server location, distance calc, random payload.
  getip_util.go         Client IP extraction, proxy header chain handling.
  fs.go                 http.FileSystem wrapper that hides directory listings.
  assets/               The entire front end (served and embedded):
    index.html              default page (dark/light theme, canvas gauges,
                            inline bootstrap script)
    index-modern.html       modern page, loads javascript/index.js, supports
                            multi-server mode via server-list.json
    index-classic.html      legacy compact page (self-contained inline JS)
    stability.html          packet-loss / stability test page
    example-*.html          standalone API usage examples
    speedtest.js            public Speedtest() API facade
    speedtest_worker.js     the actual test logic (Web Worker)
    stability_worker.js     stability test worker
    javascript/             shared page scripts (gauges.js, index.js)
    styling/                shared CSS (colors.css = design tokens)
    fonts/ images/
results/
  telemetry.go          POST /results/telemetry handler, PNG rendering
                        (embedded NotoSans fonts), grade calculation.
  json.go               /results/json API, value formatting.
  stats.go              /stats page: session auth, search, pagination.
  view.go               /results/view HTML result page.
  idobfuscation.go      optional ULID obfuscation (NOT cryptographic).
  schema (see below)    test helpers live here as *_test.go.
database/
  database.go           DataAccess interface + SetDBInfo() switch.
  schema/schema.go      TelemetryData record type, SearchFilters.
  schema/filters.go     filter parsing/matching for the stats page.
  memory/ none/ bolt/ sqlite/ mysql/ postgresql/ mssql/   drivers,
                        each exposing Open(...) and implementing
                        database.DataAccess.
server-list.json        Multi-point-of-test server list (modern front end).
settings.toml           Runtime configuration (documented inline).
Dockerfile              Multi-stage build → scratch image, port 8989.
Dockerfile.build       Multi-stage build (golang:1.25-alpine → scratch) used
                        to produce a binary-only archive for distribution
                        packages; `build_pkgs` invokes it with
                        `--target bin_builder` (copies only the compiled
                        `speedtest` binary, no assets or config).
.goreleaser.yml         Cross-platform release builds.
.github/workflows/      release.yml (manual), docker-publish.yml,
                        arm-registry.yml.
rpm/ systemd/           Packaging artifacts.
deb/                    Debian packaging: control, maintainer scripts, systemd
                        unit, settings.toml, server-list.json, build.sh.
deb/build/              Build output from `./deb/build.sh` — do not commit.
build/                  Untracked local build artifacts — do not commit.
```

### Request flow

1. `main.go` → `config.Load()` → `web.SetServerLocation()` →
   `results.Initialize()` → `database.SetDBInfo()` → `web.ListenAndServe()`.
2. The browser page creates `new Speedtest()` (`speedtest.js`), which spawns
   `speedtest_worker.js`; the worker hits `/garbage` (download), `/empty`
   (upload/ping) and `/getIP` on this server.
3. On completion the page POSTs results to `/results/telemetry`; the record is
   stored through `database.DB` (the `DataAccess` interface) and can be read
   back via `/results/json`, `/results/view`, `/stats` and the PNG endpoint.

When adding a database backend: implement `database.DataAccess` in a new
sub-package and register it in `database.SetDBInfo()`.

## Core code style

### Go

- **Formatting**: `gofmt` canonical output — tabs for indentation. A few
  pre-existing files have minor alignment drift; run `gofmt -l .` and format
  the files you touch rather than reformatting the whole tree.
- **Imports**: grouped stdlib → project
  (`github.com/librespeed/speedtest-go/...`) → third-party, one blank line
  between groups, `gofmt`-sorted within each group. Alias logrus as
  `log`: `log "github.com/sirupsen/logrus"`.
- **Naming**: idiomatic Go — `camelCase` locals/fields, `PascalCase` exported
  names, no stuttering (`config.Config`, not `config.ConfigConfig`).
  Struct fields that map to config keys carry `mapstructure:"snake_case"`
  tags; JSON-facing structs carry `json:"camelCase"` tags.
- **Errors**: `if err != nil {` on its own line. Fatal startup problems use
  `log.Fatalf`; runtime problems in handlers use `log.Errorf` +
  `http.Error(w, ..., http.StatusXxx)` with a client-safe message (never leak
  internals). Return `error` from `startListener`-style functions.
- **Comments**: full-sentence comments that explain *why*, not what — the
  codebase documents security decisions, privacy caveats and compatibility
  constraints in detail (see `schema.ClientID`, `idobfuscation.go`,
  `stats.DeviceGroup`). Keep that level of rationale for anything touching
  security, privacy, or client-supplied input.
- **Security**: input from clients (headers, Host, form values, IDs) must be
  validated before use; prefer rejecting over sanitizing.
- **Concurrency**: use `sync.Once` for lazy globals (see `results/stats.go`),
  `sync.Mutex` for shared state; no goroutine leaks.
- **Tests**: standard `testing` package, table-driven with a `name` field per
  case (see `results/telemetry_test.go`). Run `go vet` and `go test ./...`.
- Avoid deprecated stdlib (`io/ioutil` still appears in old code — prefer
  `io.ReadAll` / `os.ReadFile` in new code).

### JavaScript

There are two generations of front-end code; **match the file you edit**.

- Newer page scripts (`javascript/index.js`, `javascript/gauges.js`,
  `stability.html` inline script):
  - 2-space indent, single quotes, semicolons, `const`/`let` (no `var`),
    arrow functions, `async/await`, optional chaining (`?.`).
  - Plain classic scripts — **no ES modules, no imports/exports**; scripts
    share globals through `<script>` tag order (e.g. `gauges.js` must load
    before `index.js`).
  - `/** ... */` file header describing purpose, `//── Section ──` divider
    comments, and short rationale comments above non-obvious logic.
- Legacy core (`speedtest.js`, `speedtest_worker.js`,
  `stability_worker.js`, `index-classic.html` inline script):
  - `var`, `function` declarations, prototype/object-literal methods,
    double quotes dominant; `speedtest_worker.js` and `index-classic.html`
    are tab-indented, `speedtest.js` is space-indented.
  - Preserve the existing header comment block and LGPL attribution.
- Keep worker ↔ main-thread message contracts intact: the worker posts a
  flat status object (`dlStatus`, `ulStatus`, `pingStatus`, `jitterStatus`,
  `testState`, progress fields, …) consumed by `speedtest.js` and every page.
- Endpoint URLs default to the PHP-style names (`garbage.php`, `empty.php`,
  `getIP.php`) for compatibility — the Go server aliases them; don't rename.
- No build step: files under `web/assets/` are served verbatim and embedded
  into the binary (`//go:embed assets` in `web/web.go`). After editing assets,
  rebuild the Go binary to test the embedded fallback.

### HTML

- `<!DOCTYPE html>`, `<html lang="en">`, UTF-8 and viewport meta tags.
- Newer pages (`index.html`, `index-modern.html`, `stability.html`):
  2-space indent, semantic `<header>/<main>/<footer>` structure, page-specific
  CSS in an inline `<style>` block, shared CSS from `styling/*.css`.
- Legacy pages (`index-classic.html`, `example-*.html`) vary (tabs or minimal
  markup) — keep their local style when editing.
- Design tokens are CSS custom properties in `styling/colors.css` and the
  `:root` block of each page; the light theme is applied via
  `[data-theme="light"]`. Canvas gauges read some colors from CSS variables
  at draw time — keep JS and CSS token names in sync (see comments in
  `gauges.js`).
- Script load order in `<head>`: `speedtest.js` first, then any inline config
  (e.g. `SPEEDTEST_SERVERS`), then `javascript/*.js`.
- Include the small inline "prevent flash of wrong theme" snippet at the top
  of `<head>` when adding a new themed page.
- Keep `id`/`class` names stable — the JS files reference them directly and
  there is no templating layer to catch typos.

## Things to avoid

- Do not add a JS toolchain (npm/webpack/vite) or introduce ES modules unless
  explicitly asked; the project intentionally ships dependency-free static
  assets.
- Do not break PHP-frontend compatibility (`.php` endpoint aliases, response
  formats) — it is an advertised feature.
- Do not commit `build/`, `deb/build/`, `dist/`, `speedtest.db`,
  `idObfuscation_salt.bin`, or binaries (see `.gitignore`).
- Do not log or expose raw client IP/PII beyond what the existing
  `redact_ip_addresses` setting allows.
- Keep the `deb/` packaging files in sync with the README "Package (Debian)"
  section: the build script, the systemd unit and the maintainer scripts must
  all describe the same install layout (`/etc/speedtest-go`,
  `/usr/share/speedtest-go/assets`, `/var/lib/speedtest-go`), and the
  `server-list.json` symlink in the assets dir must point at the
  `/etc/speedtest-go/server-list.json` conffile.
