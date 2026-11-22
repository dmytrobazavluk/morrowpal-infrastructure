# Install production from scratch

Begin with the [shared installation prerequisites](../../shared/docs/installation-prerequisites.md)
and [production prerequisites](./installation-prerequisites.md), then follow the
[shared installation guide](../../shared/docs/install-from-scratch.md).

The shared guide covers reviewed resource creation, host/storage preparation,
DNS/TLS, and a guarded initial deployment with backend, app, and website tags
supplied together. Every command selects its environment explicitly.

Production already exists. Use the update or
[host-replacement procedure](./replace-host.md) for that environment. Do not
recreate production stacks or retained resources by following a fresh install.
Production writes require completed staging validation, the final parity audit,
and explicit approval.
