# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for a
vulnerability.

Use GitHub's private reporting: go to the repository's **Security** tab →
**Report a vulnerability** (GitHub Security Advisories). If that is
unavailable, open a regular issue asking for a private contact channel
*without* including any details of the vulnerability.

We aim to acknowledge a report within a few days. Please give us a reasonable
window to release a fix before any public disclosure.

## Supported versions

Security fixes are applied to the latest `main`; there are no separately
maintained release branches.

## Scope and threat model

image64 is a local, offline desktop app; it is **not** a network service,
makes no network connections, and handles no user credentials. Understanding
what it does with your machine helps you assess risk:

- **Image decoding.** The app decodes whatever image file you drop, open, or
  paste, using Apple's ImageIO/Core Image frameworks. A maliciously crafted
  image attacking the *decoder* is a platform issue (report those to Apple);
  a crafted image causing image64 itself to misbehave — crashes, unbounded
  memory growth, or writes outside the chosen export path — is in scope.
- **Filesystem access.** The app reads only the image files you explicitly
  give it and writes only through the standard macOS save panel to the
  location you choose. It keeps no database and phones nothing home.
- **Exported files.** Exports are plain data (C64 bitmap/color bytes with a
  two-byte load address, or a PNG). They contain no executable host code.
  What a C64 or emulator does when *displaying* them is out of scope — as is
  the behavior of VICE or other software you load them into (report those to
  their respective projects).
