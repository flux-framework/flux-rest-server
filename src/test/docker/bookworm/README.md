# Docker-based testing

Self-contained Docker environments for exercising flux-rest-server's two
modes without requiring root or sudo on a real host.

- **[`local-mode/`](local-mode/)** - flux-rest-server as a background
  subprocess inside a user's own Flux instance. No nginx, systemd, or
  polkit involved. Simplest starting point.

- **[`system-mode/`](system-mode/)** - the full production design:
  `nginx -> auth_request -> polkit -> systemd socket activation ->
  per-user flux-rest-server -> flux_open() as guest`. Requires a
  `--privileged` container (to run systemd and polkit for real inside
  it) and several supporting config files, all included. Its README
  includes a step-by-step breakdown for verifying each layer of the
  chain individually, and documents several non-obvious build/runtime
  requirements discovered while putting this together.

If you're not sure which you need: local mode answers "does
flux-rest-server work at all"; system mode answers "does the full
enterprise-deployment trust chain work as designed."

Neither of these directories participates in the autotools build; they're
standalone Docker environments, invoked directly per their own READMEs.
