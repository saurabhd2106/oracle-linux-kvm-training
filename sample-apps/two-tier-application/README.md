# Two-tier application (Node API + PostgreSQL)

Product catalog API that stores data in PostgreSQL. Use this lab to teach how a
backend container talks to a database container over a Docker network.

## Architecture

```text
Host (curl) --> backend:3000 --> db:5432 (PostgreSQL)
```

## Learning goals

- Custom bridge networks and DNS by container/service name
- Passing DB credentials with environment variables (never bake secrets into images)
- Named volumes for database persistence
- Healthchecks + `depends_on: condition: service_healthy`
- Manual `docker run` vs Docker Compose

## API

Same contract as the single-tier samples (`/health`, `/api/products`, …).
`/health` also checks the database (`{"status":"ok","database":"up"}`).

## Lab A — Manual networking (teach this first)

### 1. Create a network and a volume

```sh
cd sample-apps/two-tier-application
docker network create shop-net
docker volume create shop-pgdata
```

### 2. Start PostgreSQL

```sh
docker run -d \
  --name shop-db \
  --network shop-net \
  --network-alias db \
  -e POSTGRES_USER=catalog \
  -e POSTGRES_PASSWORD=catalog \
  -e POSTGRES_DB=catalog \
  -v shop-pgdata:/var/lib/postgresql/data \
  -p 5432:5432 \
  postgres:16-alpine
```

Wait until ready:

```sh
docker exec shop-db pg_isready -U catalog -d catalog
```

### 3. Build and start the backend

```sh
docker build -t two-tier-backend:1.0 ./backend

docker run -d \
  --name shop-backend \
  --network shop-net \
  -e DATABASE_HOST=db \
  -e DATABASE_PORT=5432 \
  -e DATABASE_USER=catalog \
  -e DATABASE_PASSWORD=catalog \
  -e DATABASE_NAME=catalog \
  -p 3000:3000 \
  two-tier-backend:1.0
```

Key teaching point: inside the backend container, hostname `db` resolves to the
Postgres container because of `--network-alias db` on the shared network.

### 4. Verify connectivity

```sh
curl http://localhost:3000/health
curl http://localhost:3000/api/products

docker exec -it shop-backend sh -c 'getent hosts db; wget -qO- http://127.0.0.1:3000/health'
docker exec -it shop-db psql -U catalog -d catalog -c 'SELECT * FROM products;'
```

### 5. Prove volume persistence

```sh
curl -X POST http://localhost:3000/api/products \
  -H 'Content-Type: application/json' \
  -d '{"name":"USB-C Hub","price":29.99,"inStock":true}'

docker stop shop-backend && docker rm shop-backend
# restart backend with the same docker run command from step 3
curl http://localhost:3000/api/products
# Your new product is still there because Postgres data lives in shop-pgdata
```

### 6. Cleanup (manual lab)

```sh
docker stop shop-backend shop-db
docker rm shop-backend shop-db
docker network rm shop-net
# WARNING: deletes product data
docker volume rm shop-pgdata
```

## Lab B — Docker Compose (production-friendly)

```sh
cd sample-apps/two-tier-application
docker compose up -d --build
curl http://localhost:3000/health
curl http://localhost:3000/api/products
docker compose ps
docker compose logs -f backend
```

Inspect the DB:

```sh
docker compose exec db psql -U catalog -d catalog -c 'SELECT * FROM products;'
```

Stop containers but keep data:

```sh
docker compose down
```

Stop and **delete the volume** (data loss demo):

```sh
docker compose down -v
```

## Run backend locally against Compose DB (optional)

```sh
docker compose up -d db
cd backend && npm install
DATABASE_HOST=localhost DATABASE_USER=catalog DATABASE_PASSWORD=catalog \
  DATABASE_NAME=catalog npm start
```

## Dockerfile / Compose highlights

- Backend image is multi-stage and non-root
- Compose waits for Postgres health before starting the API
- Credentials come from environment variables, not from the image
- Named volume `pgdata` persists `/var/lib/postgresql/data`
