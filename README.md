# elpaca-build-augment

An extension for [Elpaca](https://github.com/progfolio/elpaca) that replays
per-package build steps upstream package archives run on their build servers,
so packages install from source into a complete, feature-ready state — not a
partial one.

## The problem

Elpaca installs a package by cloning its source, byte-compiling the elisp, and
generating autoloads. For most packages that is everything needed. For roughly
16% of GNU/NonGNU ELPA packages (and a smaller slice of MELPA packages), there
are additional build steps that upstream *does* run — on the ELPA/MELPA build
server — but that Elpaca does not replay locally.

Concrete examples of what gets lost:

- AUCTeX ships `latex/preview.sty` and friends only after `make elpa` runs.
  Without that step, the `preview-latex` feature fails with `File 'preview.sty'
  not found.` at LaTeX time.
- ESS, Eat, Evil, Bongo and dozens of others ship Info manuals that only exist
  after `makeinfo` runs — in some cases with `cd` into a `doc/` subdirectory
  first so `@include` paths resolve, in others with a preceding `make` to
  generate a `version.texi`.
- A handful of packages (Hyperbole, Tramp, flymake-collection, etc.) need a
  `make` target that produces a `.el` file at runtime.

`package.el` sidesteps all of this by downloading pre-built tarballs that the
upstream build server already assembled. Elpaca installs from source, which is
more flexible — pin a commit, follow a branch, patch locally — but means every
build quirk would have to be replayed on the user's machine. This library does
the replay.

## How it works

A single hook on `elpaca-recipe-functions`. For each package Elpaca resolves,
the hook branches:

1. **Metadata-driven path.** If the package has a `:make`, `:doc`, or
   `:shell-command` entry in GNU/NonGNU ELPA's `elpa-packages` file (fetched on
   first use and cached locally), synthesize exactly those commands:

   ```
   :shell-command CMD   -> sh -c CMD   in source dir
   :make TGT            -> make TGT    in source dir
   :doc "D/F.texi"      -> cd D && makeinfo F.texi -o F.info
   ```

   Then mirror ELPA's "ship everything in source" packaging rule, honoring
   `:lisp-dir`, `:ignored-files`, and `:excludes` from the same entry.

2. **Heuristic path.** For MELPA-only packages (or ELPA entries without build
   fields): scan the source tree for `.texi` files, keep ones that look like
   standalone manuals (have `@setfilename` or start with `\input texinfo`), run
   `makeinfo --force` on each from its own directory. `@include` fragments
   (fdl.texi, gpl.texi, etc.) are detected and skipped.

3. **Respect existing `:build`.** Recipes that already set `:build` (e.g.
   `elpaca-menu-org`'s custom pipeline for Org) are left alone.

In both paths the library disables `elpaca-build-docs` (which has multi-file
`makeinfo` bugs) and queues `elpaca--install-info` so the `dir` entry gets
updated.

## Install and use

System requirements: `makeinfo` (part of texinfo), `make`, and `sh` on `PATH`.
On Windows: MSYS2 or Git for Windows provides all three.

The elisp block below goes **below** Elpaca's own installer boilerplate — see
<https://github.com/progfolio/elpaca/blob/master/doc/manual.md#installer> for
the boilerplate itself (copy it verbatim into your init before the block
below).

```elisp
;; Install elpaca-build-augment via Elpaca and enable the hook in its
;; body.  Elpaca resolves recipes synchronously at the moment each
;; `(elpaca ...)' form is evaluated -- the clone/build pipeline is
;; async, but the recipe-functions hook fires at queue time.  So the
;; hook has to be *registered* (not just textually earlier) before
;; any augmentable `(elpaca ...)' / `(use-package :ensure t)' form
;; is evaluated.  `:wait t' on the recipe tells Elpaca to install,
;; run the body (`-enable'), and only then let evaluation continue.
(elpaca (elpaca-build-augment
         :host github
         :repo "jam1015/elpaca-build-augment"
         :wait t)
  (elpaca-build-augment-enable))

;; -- Option A: use-package integration --
;; No `:wait' needed here: Elpaca's built-in `elpaca-menu-extensions'
;; already injects `:wait t' into the recipe for elpaca-use-package.
(elpaca elpaca-use-package (elpaca-use-package-mode))

(use-package auctex :ensure t :demand t) ; `make elpa' + makeinfo
(use-package ess    :ensure t)           ; cd doc && makeinfo ess.texi
(use-package eat    :ensure t)           ; makeinfo eat.texi, skip fragments
(use-package bongo  :ensure t)           ; MELPA-only; heuristic scan finds bongo.texi

;; -- Option B: raw elpaca --
(elpaca evil)                            ; NonGNU ELPA, :doc + :ignored-files
(elpaca sicp)                            ; MELPA-only; scan fails safely on broken texi
```

On first use the library fetches GNU and NonGNU ELPA's `elpa-packages` files
from Savannah into `<user-emacs-directory>/elpaca-build-augment/`. No metadata
is bundled with the package — the elisp does all the work of discovering
per-package build structure.

### Introspection

See what the library would do for a specific package:

```
M-x elpaca-build-augment-explain RET auctex RET
```

Prints the ELPA entry (if any) and the exact shell commands that would
be injected.

### Refreshing the ELPA metadata

The cached `elpa-packages` snapshots are fetched on first use. To pull fresh
copies from upstream later:

```
M-x elpaca-build-augment-refresh
```

### Overriding on a per-package basis

Nothing library-specific is needed. The hook only ever returns `:build`, and
only when the user hasn't already set it. Everything else — `:branch`, `:repo`,
`:files`, `:ignored-files` — can be adjusted inline in the `(elpaca ...)` /
`(use-package ... :ensure (...))` form; Elpaca's recipe merging gives the
user's declaration higher precedence than the menu's. To exempt a specific
package from augmentation entirely, just declare its own `:build` yourself —
the hook sees the field is set and skips the package.

```elisp
;; Change a repo field inline — hook doesn't touch :branch, so it stays.
(use-package somepkg :ensure (:branch "release"))

;; Opt out of augmentation for one package by giving it an explicit :build.
(use-package weirdpkg :ensure (:build nil))
```

## Limitations

- Packages whose build requires a C compiler plus system libraries (pdf-tools'
  `epdfinfo`, vterm's module, irony-mode's server) are installed as elisp only,
  same as under vanilla Elpaca and under `package.el`. You'll still need the
  package's own `M-x pdf-tools-install` / equivalent plus the system packages.

- GNU ELPA `:core` packages (bind-key, eglot, eldoc, erc, …) are copies of
  files inside Emacs's own source tree, not independent repos. There is nothing
  for Elpaca to clone, so this library can't install them from source. You
  already have them bundled with Emacs anyway; if you specifically want the
  ELPA-newer version, use `:type tar :inherit elpaca-menu-gnu-elpa`.


## Caveat: install-time filesystem scan

Both paths recursively walk the package's source tree at install time — the
ELPA path to build a flat `(source-file . build-file)` pair list, the heuristic
path to find `.texi` manuals. The walk is cheap for normal packages (~10 ms per
install) and happens only on install/rebuild, not on every Emacs startup, but
it's unavoidable with elpaca's current internals: `elpaca-generate-autoloads`
and friends skip symlinked directories, so we can't take the simpler route of
`:files ("*" (:exclude ...))` and let elpaca symlink `lisp/` as a whole
directory — nested `.el` files would be invisible to autoload scanning. We have
to symlink files individually.

If upstream Elpaca ever grew the ability to follow directory symlinks the walks
here could be shrunk or removed entirely.

## License

GPLv3+. See [LICENSE](LICENSE).
