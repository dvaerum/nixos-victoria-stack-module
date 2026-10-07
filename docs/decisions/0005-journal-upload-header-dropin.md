# 0005: journald-upload write-token via a conf.d drop-in, not a hand-rolled unit

## Decision

Status: the sops-template drop-in mechanism is superseded by ADR 0012; the
reasoning for using a drop-in rather than a hand-rolled unit stands.

`services.victoriaCollector`'s logs-write-path keeps using nixpkgs' own
`services.journald.upload` module for every non-secret setting (URL, client-cert
loading disabled, trust bundle) exactly as the original `common/victoria-collector`
did. The bearer token is carried separately via
`environment.etc."systemd/journal-upload.conf.d/50-write-token.conf".source`
pointed at a `sops.templates."<name>".path` (an already-rendered, non-store
runtime path), containing just a `Header=Authorization: Bearer <token>` line.

## Why

Confirmed directly from source: nixpkgs' `journald-upload.nix` writes the
*entire* `settings` attrset into
`environment.etc."systemd/journal-upload.conf"`, which is always a Nix-store
path — world-readable. Putting a real token into
`services.journald.upload.settings.Upload.Header` directly would leak it into
the store in plaintext, the exact class of problem vmauth's own config
already had before its render-script fix.

`journal-upload.conf(5)`'s own precedence rules (confirmed from the real man
page) say drop-in snippets under `*.conf.d/` are read *in addition to* the
main config file, and for list-accepting options like `Header=`
("may be specified more than once... entries are collected"), the drop-in's
value is merged in rather than replacing the main file. This means a tiny
`environment.etc` entry symlinking straight at a sops-rendered runtime path is
enough — no hand-rolled `systemd-journal-upload` unit needed, no
`ExecStartPre` render script required for this specific piece (unlike
vmauth, which genuinely does need one, because its entire config is one
JSON blob rather than a line-merging key).

The `systemd-journal-upload` binary itself (confirmed from its own `-8`
man page) has no `--header=` or `--config-file=` CLI flag at all — `Header=`
is a config-file-only directive, so there was no simpler command-line-args
route available either.
