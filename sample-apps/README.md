# Docker teaching sample apps

Hands-on sample applications for teaching Docker: Dockerfiles, images, containers,
networks, volumes, and Compose — using a shared “product catalog” API so concepts
transfer across languages.

## Prerequisites

- Docker Engine and the Compose plugin (`docker compose version`)
- Optional workstation setup: [`setup-dd`](../setup-dd/) (`install-docker.sh`)

First image pulls can take a few minutes on shared Wi‑Fi; build once before class
if you can.

## Suggested classroom path

| Order | Lab | Time | Concepts |
|------:|-----|-------:|----------|
| 1 | [sample-java-application](sample-java-application/) | 15–20 min | Multi-stage Java image, ports, health, logs |
| 2 | [sample-node-application](sample-node-application/) | 15–20 min | Node multi-stage, `NODE_ENV`, image size |
| 3 | [sample-python-application](sample-python-application/) | 15–20 min | Python/venv stages, OpenAPI `/docs` |
| 4 | [two-tier-application](two-tier-application/) | 30–40 min | Networks, DNS names, env secrets, volumes, Compose |
| 5 | [3-tier-application](3-tier-application/) | 40–50 min | nginx proxy, frontend→backend→DB |

Teach **two-tier Lab A (manual `docker network` / `docker run`) before Compose** so
delegates see why service names resolve.

## Shared API contract

All backends expose:

| Method | Path |
|--------|------|
| GET | `/health` |
| GET | `/api/products` |
| GET | `/api/products/{id}` |
| POST | `/api/products` body: `{"name","price","inStock"}` |
| DELETE | `/api/products/{id}` |

Product shape: `{ id, name, price, inStock }`.

## Command cheat sheet

```sh
# Images & containers
docker build -t name:tag .
docker images
docker run -d --name c -p HOST:CONTAINER name:tag
docker ps
docker logs -f c
docker exec -it c sh
docker stop c && docker rm c

# Networks & volumes (two-tier manual lab)
docker network create shop-net
docker volume create shop-pgdata
docker network inspect shop-net

# Compose (two-tier / three-tier)
docker compose up -d --build
docker compose ps
docker compose logs -f
docker compose exec db psql -U catalog -d catalog -c 'SELECT 1'
docker compose down
docker compose down -v   # also deletes named volumes
```

## What “good” looks like

- [ ] `docker ps` shows healthy (or running) containers
- [ ] `curl`/`browser` reaches `/health` and `/api/products`
- [ ] Two-tier: backend resolves hostname `db` (`getent hosts db`)
- [ ] Two-tier: product survives backend recreate (volume kept)
- [ ] Two-tier: `compose down -v` removes data
- [ ] Three-tier: UI at published frontend port; `/api` proxied through nginx
- [ ] No secrets baked into Dockerfiles

## Extra demos (if time)

- Compare image sizes after multi-stage vs a naive single-stage Dockerfile
- `docker inspect` for ports, env, and health status
- Bind mount for live code edit vs named volume for DB data
- Restart policy: `docker run --restart unless-stopped …`
- Optional scan: `docker scout quickview` or `trivy image …`

## Layout

```text
sample-apps/
  sample-java-application/     # Spring Boot, in-memory
  sample-node-application/     # Express, in-memory
  sample-python-application/   # FastAPI, in-memory
  two-tier-application/        # Node + PostgreSQL
  3-tier-application/          # React/nginx + Node + PostgreSQL
  README.md
```
