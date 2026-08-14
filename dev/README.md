# Development Infrastructure

This directory contains the local Docker Compose stack. Run the commands below
from this directory (`infrastructure/dev`) unless stated otherwise.

## Development Stack

Start the full local stack:

```bash
docker compose up --build -d
```

Start the stack with multiple API instances behind Envoy:

```bash
docker compose up --build -d --scale backend-api=2
```

Stop the stack:

```bash
docker compose down
```

Envoy listens on `127.0.0.1:8080` and balances traffic across the `backend`
API containers.

The database listens on `127.0.0.1:3307`.

The stack includes:

- `mysql`
- `backend-api`
- `backend-job-dispatch`
- `backend-job-cleanup`
- `envoy`

Job workers use separate connection-pool settings per service:

- `backend-job-dispatch`
  - `APP_JOB_DB_MAX_POOL_SIZE=4`
  - `APP_JOB_DB_MIN_IDLE=1`
- `backend-job-cleanup`
  - `APP_JOB_DB_MAX_POOL_SIZE=2`
  - `APP_JOB_DB_MIN_IDLE=1`

Default local database credentials:

- Database: `morrowpal`
- User: `morrowpal`
- Password: `morrowpal`

Data is persisted in `./mysql/data` relative to this directory.

## Backend Routing

Envoy is the only service exposed on backend HTTP port `8080`.

- Requests to `127.0.0.1:8080` go to Envoy first.
- Envoy forwards them to the internal `backend-api:8080` service.
- When `backend-api` is scaled above `1`, Envoy round-robins across the API
  containers.

The API and job containers are not published directly to the host. They are
reachable only on the Compose network.

## Scaling

Start two API instances behind Envoy:

```bash
docker compose up --build -d --scale backend-api=2
```

Change the API replica count later without rebuilding:

```bash
docker compose up -d --scale backend-api=3
```

## Logs and Status

Tail Envoy logs:

```bash
docker compose logs -f envoy
```

Tail API container logs:

```bash
docker compose logs -f backend-api
```

Tail dispatch job logs:

```bash
docker compose logs -f backend-job-dispatch
```

Tail cleanup job logs:

```bash
docker compose logs -f backend-job-cleanup
```

List the API containers created by scaling:

```bash
docker compose ps backend-api
```

## Rebuilding

Rebuild the API image after backend changes:

```bash
docker compose up --build -d backend-api
```

Rebuild the job images after backend changes:

```bash
docker compose up --build -d backend-job-dispatch backend-job-cleanup
```

Rebuild and restart the load-balanced local stack:

```bash
docker compose up --build -d --scale backend-api=2 backend-api backend-job-dispatch backend-job-cleanup envoy
```

## Health Checks

Check the backend health through Envoy:

```bash
curl http://127.0.0.1:8080/health
```

Check readiness through Envoy:

```bash
curl http://127.0.0.1:8080/ready
```
