# org-constellation

Turns org notes into stars, and the links between them draw the constellations. Pick a star and see what links to it, what it links to, and what you mentioned in the journal.
Works with a folder of `.org` files or a single `.org` file.

<img width="1919" height="1079" alt="2026-10-20_08-14" src="https://github.com/user-attachments/assets/7ed28c65-a4a6-4504-90dd-dad894bb17a4" />



## Setup

Put `constellation.el` on your `load-path`, then:

```elisp
(require 'constellation)
(setq constellation-sources '("~/org"))   ; files and/or directories
```

Run `M-x constellation`.

If `constellation-sources` is not set, `org-directory` is used.

## What counts as a note

- Several files: every `.org` file is a note.
- One file: every top-level heading is a note (change with `constellation-heading-level`).
- Files named like `2026-10-19.org` or `20261019.org`, and headings starting with a date, are treated as a journal. They are not notes, but they provide dates and "mentioned together" connections.

Links understood: `[[Title]]`, `[[*Heading]]`, `[[file:x.org]]`, `[[id:UUID]]` and external links. A `[[Title]]` with no matching note appears as a dim "ghost" note.

## Keys

| Key | Action |
|---|---|
| `j` / `k` | next / previous note in the list |
| `h` / `l` | walk the chart; `RET` dives into the highlighted note |
| `J` / `K` | pick the next / previous link or journal entry in the note |
| `RET` | follow the picked item (a journal entry opens its file at that line) |
| `o` | open the picked item in its file |
| `m` | pick the next journal mention |
| `u` | back |
| `/` | filter the list |
| `s` | sort: recent / most linked / A-Z |
| `v` | layout: chart + note / note / chart |
| `e` | edit the note in its file |
| `g` | re-read the files |
| `q` | quit |

## Options

`constellation-sources`, `constellation-node-kind`, `constellation-heading-level`, `constellation-journal-file-regexp`, `constellation-exclude-regexp`, `constellation-height-margin` (set to 2 if the key bar is cut off).

## License

GPL-3.0-or-later
