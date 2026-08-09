# Infrastructure

Infrastructure configuration and operational documentation are separated by
environment:

- [Development](./dev/README.md) contains the local Docker Compose stack,
  service layout, scaling, logs, and health checks.
- [Production](./prod/README.md) contains installation, deployment, TLS,
  host operations, and administration procedures.

Choose the environment before running commands. Development commands operate
only on the local Compose stack; production commands target AWS and the
production EC2 host.
