# 0006: Alloy's write-token via otelcol.auth.bearer + a systemd credential, not inline

## Decision

Principle: a token is handed to a service with systemd `LoadCredential=`
whenever the service can read it from the credentials directory.

Alloy can. `alloy.service` loads `services.victoriaCollector.writeTokenFile` as
the `write-token` credential and its config reads it:

```
local.file "write_token" { filename = "/run/credentials/alloy.service/write-token"  is_secret = true }
otelcol.auth.bearer "write_token" {
  token = string.trim_space(convert.nonsensitive(local.file.write_token.content))
}
```

The token never appears in the rendered `config.alloy`, in an environment
variable, or in a unit file. The `string.trim_space` drops the file's trailing
newline, which is not a valid header value. `is_secret = true` and the secret
type of `otelcol.auth.bearer`'s `token` keep the value out of Alloy's loopback
web UI (`(secret)`); `otelcol.auth.headers` was dropped earlier because its
`value` is a plain string that printed `Bearer <token>` to any local user.

An `ExecStartPre=` check reads the credential and refuses a file that is empty
or has several lines, with a message naming `writeTokenFile` and never the
token.

The first design (an `EnvironmentFile=` written by a render oneshot, with
`sys.env`) is gone: a token file that arrived after boot failed the oneshot,
which failed alloy's start job as "dependency failed", and nothing retried it.

## Late and changed files

A credential is a copy taken when the unit starts, so a missing file fails the
start and a replaced file is not seen by a running unit. Two path units handle
both without polling (details in the unit definitions):

- `PathExists=` starts the consumers once, through a `RemainAfterExit` helper so
  the path unit does not trigger again while the file exists; a deliberate
  `systemctl stop` is not undone by a later change to the file, nor by a
  `switch` that changes the helper's unit file (`restartIfChanged = false`).
- `PathChanged=` runs `try-restart --no-block` (a stopped unit stays stopped; the
  path unit only re-arms once its helper ends, so waiting would lose a file
  replaced meanwhile). A live swap is not possible with `LoadCredential=`; the
  restart is the accepted cost, and unsent data waits in the disk queue.

The uploader's write-token oneshot is covered by the same units
(docs/decisions/0012).
