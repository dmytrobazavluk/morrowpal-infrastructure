# Update production infrastructure

Use the [shared infrastructure update procedure](../../shared/docs/update-infrastructure.md).
It requires an explicit environment selection and uses the guarded deployment
wrapper for both staging and production.

Production work requires completed staging validation, the final parity audit,
and explicit approval. Select `prod` only after that gate is satisfied.
