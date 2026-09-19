# Planned features + SEO notes

Scratch notes from a planning/discussion session, kept for reference.
**Not committed on purpose** — working notes, not a deliverable.

## "Tier 1.5" idea: test against Termux's real glibc build (investigated, not built)

Raised after the Tier-1 workflow shipped: can GitHub-hosted runners be
pushed further without crossing into self-hosted-runner territory?
User asked to check how VSCodium handles this.

**VSCodium research (2026-09-17)**: fetched
`.github/workflows/ci-build-linux.yml` from VSCodium/vscodium. Findings:
- Their ARM64 AppImage job already uses `runs-on: ubuntu-24.04-arm` —
  the same native-arm64-hosted-runner approach this repo's
  `track-claude-release.yml` uses. Confirms that's the right modern
  choice, not something being missed.
- Other Linux variants cross-compile inside arch-specific Docker images
  (`vscodium/vscodium-linux-build-agent:focal-{x64,arm64,armhf}`) run on
  `ubuntu-latest` — for producing foreign-arch *builds*, not for testing.
- **They never execute/run the built binary in CI at all** — purely
  build-and-upload-artifact. So this repo's current smoke test
  (`--version` actually running) is already a step ahead of what
  VSCodium itself does.
- No QEMU usage found for testing; `docker/setup-qemu-action` is a
  general Docker buildx cross-arch tool, unrelated to what VSCodium does
  and not something that would help test Bionic-kernel-specific behavior
  anyway (QEMU user-mode emulation translates syscalls to the *host*
  kernel — running under QEMU on a Linux host still means a real Linux
  kernel underneath, not a real Android kernel, so it can't reproduce a
  kernel-level bug like the epoll_pwait2 trap any better than a native
  arm64 Linux runner can).

**What IS newly possible, confirmed by direct survey of Termux's own apt
repo** (`https://packages-cf.termux.dev/apt/termux-glibc/`, dists/glibc,
binary-aarch64 `Packages` index, fetched 2026-09-17): the exact `.deb`
files Termux's `pkg install glibc glibc-runner patchelf` pulls are
directly downloadable with plain `curl`, no Termux/pkg/Android needed:
- `glibc` (v2.44 as of this check):
  `pool/stable/g/glibc/glibc_2.44_aarch64.deb` — contains the real
  `ld-linux-aarch64.so.1` + Termux's actual glibc shared libraries.
- `patchelf-glibc` (v0.19.1):
  `pool/stable/p/patchelf-glibc/patchelf-glibc_0.19.1_aarch64.deb`.
- `glibc-runner` (v2.0-3, arch `all`): the `grun` wrapper script itself
  (not needed for our purposes — this repo's own wrapper does the direct
  interpreter-swap exec, doesn't go through `grun`).
- Confirmed by actually downloading `patchelf-glibc_0.19.1_aarch64.deb`
  and inspecting its `data.tar.xz` (standard `.deb` = `ar` archive of
  `debian-binary` + `control.tar.xz` + `data.tar.xz`): package contents
  use **hardcoded absolute paths** baked in as
  `./data/data/com.termux/files/usr/glibc/...` — not relocatable via a
  normal install prefix. To use on a generic Ubuntu ARM64 runner:
  `dpkg -x <deb> <scratch-dir>` (works standalone, dpkg is preinstalled
  on GitHub's Ubuntu images, no root needed since it just extracts to an
  arbitrary target dir) then reference the loader at
  `<scratch-dir>/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1`
  directly with `--library-path <scratch-dir>/data/data/com.termux/files/usr/glibc/lib`
  — same invocation pattern `scripts/update.sh`/`claude-wrapper.sh`
  already use against the real `$PREFIX`, just pointed at the extracted
  scratch tree instead.

**What this would add over the current Tier-1 smoke test**: verifies the
downloaded `claude` binary actually loads and runs against Termux's
*real, currently-shipped* glibc/patchelf build specifically — catching a
Termux `glibc-repo` package regression or ABI drift that the current
test (which just runs `--version` against the GitHub runner's own Ubuntu
system glibc) would miss, since Ubuntu's system glibc version won't
generally match whatever Termux's `termux-glibc` repo currently ships.

**What it still would NOT catch**: anything genuinely kernel-level —
the epoll_pwait2 trap specifically, or any other real-Android-kernel
syscall quirk. A GitHub-hosted runner (arm64 or otherwise) always runs a
real Linux kernel, never a real Android/Bionic kernel, no matter what
userland (Ubuntu's own, or Termux's extracted glibc package) sits on top
of it. Only Tier 2 (self-hosted runner on an actual Android device)
closes that specific gap, and that was set aside for the public-repo
self-hosted-runner security reason described below.

**Status: investigated and technically confirmed feasible, not yet
implemented.** Not scoped into a concrete workflow-file plan yet — next
step if picked back up is turning the invocation pattern above into an
additional step (or a separate job) in `track-claude-release.yml`, and
deciding whether a Termux `glibc`-package mismatch should block the
release or just annotate it as a secondary check.

## Status of features discussed this session

### Done (implemented, tested, not yet committed/pushed as of this note)
- **Version pinning** — `termux-update-claude --pin [VERSION]` / `--unpin`.
  `scripts/update.sh`, `scripts/doctor.sh`, `uninstall.sh` all touched.
  See `/data/data/com.termux/files/home/.claude/plans/iterative-imagining-sunset.md`
  for the full design (`check_platform` also relocated from `install.sh`
  into `scripts/lib.sh` as part of this work).
- **Migration tool** (`migrate.sh`, new file) — detects an old plain-npm
  Claude Code install on Termux (pre-v2.1.113, before Anthropic dropped
  the JS fallback — anthropics/claude-code#50270), backs it aside (never
  deletes), hands off to `install.sh`. Tested against a fake npm tree in
  the scratchpad; the backup step was fixed mid-testing to rename the
  PATH-visible symlink rather than the resolved target, so a real npm
  package's files under `node_modules` stay intact for `npm uninstall`.

### Done (implemented, not yet pushed as of this note)
- **Release-tracking GitHub Actions workflow**
  (`.github/workflows/track-claude-release.yml`) — Tier 1 (detect + smoke
  test, see below), built after the user confirmed they wanted it. Tier 2
  (self-hosted runner on the phone) was offered first since the user
  volunteered to keep Termux uptime for it, but once the public-repo
  self-hosted-runner security warning was raised (GitHub explicitly
  advises against it — a workflow ever gaining a `pull_request`-style
  trigger would let anyone who can open a PR run code on the runner
  machine), the user chose to fall back to Tier 1 instead. Runs hourly +
  `workflow_dispatch`, `permissions: contents: write` at the workflow
  level (confirmed to override the repo's `read` default fine, no GitHub
  settings change needed), tag format `claude-<version>`.

  Three tiers were on the table; only Tier 1 is built:
  1. Detect + tag only (no execution test) — not built, superseded by 2.
  2. **Built.** Smoke test on GitHub's hosted `ubuntu-24.04-arm` runner
     (real arm64, free for public repos). Since the shipped binary is
     plain `linux-arm64` glibc, it runs directly on real aarch64 glibc
     Linux with **no patchelf step needed** — confirms the binary isn't
     corrupted / checksum is right / `--version` actually executes. Does
     **not** catch Bionic/Termux-specific breakage (e.g. the trap #9
     `epoll_pwait2` TLS-fault bug documented in the main README — that's
     specific to running through Termux's glibc-runner on an Android
     kernel, and doesn't reproduce on genuine glibc Linux).
  3. **Declined for now**, for the security reason above. Would have used
     a self-hosted runner on a real Termux/Android device running
     `actions-runner` continuously — the only tier that would catch
     something like trap #9, at the cost of a device having to stay on
     indefinitely and a standing code-execution surface on that device.
     Revisit only with the trigger list still restricted to
     schedule/`workflow_dispatch` — never `pull_request`/
     `pull_request_target` on this runner while the repo is public. No
     credible middle ground exists either: an Android emulator in CI was
     considered and ruled out (arm64 system image on an x86 host means
     double emulation, very slow/flaky; Termux isn't designed to run
     headless/non-interactively anyway).

## SEO notes (from a clipboard note the user pasted, 2026-09-17)

Original note, verbatim:

> Vài thủ thuật thực tế để repo dễ được tìm thấy và dùng hơn trên GitHub:
>
> **Trên GitHub:**
> - **Topics** (thẻ ở phần "About"): thêm các từ khóa như `claude-code`, `termux`, `android`, `glibc`, `patchelf`, `claude-ai` — đây là thứ GitHub dùng để gợi ý repo trong search/explore.
> - **Description ngắn gọn, đúng từ khóa** người ta sẽ gõ khi search (ví dụ "Run Claude Code natively on Termux/Android" — đã có sẵn kiểu này rồi).
> - **README có demo GIF/ảnh ngay đầu** (đã có) — repo có ảnh minh họa tỷ lệ click-through cao hơn nhiều trong kết quả search.
> - **Star/fork ban đầu**: rủ vài người quen star giúp — GitHub trending và search ranking bị ảnh hưởng bởi star velocity trong tuần đầu.
>
> **Ngoài GitHub (quan trọng hơn cho SEO Google thật sự):**
> - README của bạn **được Google index** — nên có đúng cụm từ người dùng sẽ search, ví dụ lặp lại tự nhiên các cụm như "Claude Code Termux Android", "claude code native android install", tránh chỉ viết tắt.
> - Trả lời/link repo vào chính GitHub issue anthropics/claude-code#50270 (issue về lỗi native binary trên Termux) — đây là nơi đúng người đang gặp đúng vấn đề tìm đến, traffic rất tập trung.
> - Nộp vào các **awesome-list** liên quan (ví dụ `awesome-claude-code` nếu có) — các list này được index tốt và nhiều người browse.
> - Đăng lên r/Termux, r/LocalLLaMA, hoặc Hacker News "Show HN" — traffic ban đầu giúp cả GitHub trending lẫn backlink cho SEO.
> - Giữ repo có hoạt động đều đặn (commit, release) — repo "còn sống" được ưu tiên hơn trong kết quả search so với repo im lìm nhiều tháng.
>
> Một lưu ý: license GPL-3.0 bạn vừa đổi cũng nên được nêu rõ trong description/README vì nhiều người lọc theo license khi tìm repo để dùng.

### Already satisfied / done, no action needed
- Topics: repo already had `claude-code`, `termux`, `android`, `glibc`,
  `patchelf`, `anthropic`, `aarch64`, `linux-arm64`. Added `claude` and
  `bionic` on 2026-09-17 (`gh repo edit --add-topic`).
- Description already keyword-matches likely search phrasing ("Run
  Claude Code natively on Termux/Android...").
- Demo GIF already at the top of README (`assets/demo.gif`).
- License: GitHub's own license filter reads the `LICENSE` file directly
  (already GPL-3.0 as of this session) — doesn't need restating in the
  description field for that filter to work. Could still add to the
  description text for a human skimming it, but not required for GitHub
  search/filter mechanics.
- Repo activity: this session's commits (pinning, migrate.sh, README) are
  exactly the kind of "still alive" signal the note describes — no
  separate action needed beyond actually pushing them.

### Needs the user's own action / explicit go-ahead — not done unilaterally
- Reply on anthropics/claude-code#50270 linking this repo — public post
  on someone else's issue, offered to draft it, user hasn't said go yet.
- Submit to `awesome-claude-code` (or similar) — needs a PR to a
  different repo.
- Post to r/Termux, r/LocalLLaMA, or HN "Show HN" — social action, not
  something to do on the user's behalf.
- Asking people to star — the user's own network, not actionable by me.
