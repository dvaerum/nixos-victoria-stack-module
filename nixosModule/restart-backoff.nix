# The restart backoff of every module-owned unit that restarts itself, shared by
# the stack and the collector (docs/decisions/0015). The first retry waits the
# unit's own RestartSec=; later ones grow geometrically over RestartSteps steps
# up to RestartMaxDelaySec (systemd >= 254), so a unit that cannot start stops
# filling the journal. Measured: RestartSec=5 waits 5, 9, 16.5, 30 s, Alloy's
# RestartSec=2 waits 2, 5, 12, 30 s. The cap is low because systemd never
# resets the growth after a healthy run.
{
  RestartSteps = 3;
  RestartMaxDelaySec = 30;
}
