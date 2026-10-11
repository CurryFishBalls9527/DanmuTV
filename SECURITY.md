# Security policy

Danmu TV handles Bilibili login credentials and runs a cast receiver on the local network, so security reports matter.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private reporting instead: the repository's **Security** tab ›
**Report a vulnerability**. Include what's affected, how to reproduce it, and the impact you see.

You can expect an acknowledgement within a week. Fixes land on `main`; there are no separately maintained releases.

## Scope

In scope: credential storage and handling, the cast receiver (SSDP / HTTP / NVA on the local network), anything that
could leak account data or let another device on the network do more than start, control or stop playback.

Out of scope: Bilibili's own services and apps, and issues that require a jailbroken device.
