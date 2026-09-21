# Release notes

The generator (`release-notes.sh`, from mavericks-shipyard) writes the notes file for every
release: the title, a "What changed" section, a "Build ingredients" section when a pin moved,
and the footer. That one file, `dist/RELEASE_NOTES.md`, becomes the GitHub Release body AND
both Sparkle appcast `<description>`s (native and cross) -- the same bytes, read three times.

The footer's install-floor line describes the native `.pkg` (`--min-os 10.9.5`), the variant
most users install. The cross variant's own, different minimum (it runs on modern
Apple-Silicon macOS; it does not carry a 10.9 floor) lives only in `appcast-cross.xml`, via its
own `sign_and_appcast.sh --min-os` argument -- the notes describe the product, each appcast
describes the artifact it serves.

A file here, named `<full-version>.md` (e.g. `22.1.1-mavericks.1.md`), is OPTIONAL hand-written
prose for that one release. When present, it is inserted verbatim right after the generated
title. It must NOT start with its own `## ` heading -- the generator already emits the title;
a second one would double it.

Most releases have no file here at all, and that's fine: the generator's own sections are the
whole note.
