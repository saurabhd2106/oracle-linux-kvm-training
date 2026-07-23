# Sample Node application (Express)

In-memory product catalog API used to teach building and running a single Node.js
container with a multi-stage Dockerfile.

## Learning goals

- Multi-stage Node builds (deps install → slim runtime)
- `NODE_ENV=production` and omitting dev dependencies
- Port publishing, healthchecks, logs, `docker exec`
- Comparing image sizes (`docker images`)
- Non-root `USER`

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness |
| GET | `/api/products` | List products |
| GET | `/api/products/{id}` | Get one product |
| POST | `/api/products` | Create product (`{"name","price","inStock"}`) |
| DELETE | `/api/products/{id}` | Delete product |

## Run without Docker (optional)

Requires Node.js 20+:

```sh
npm install
npm start
curl http://localhost:3000/health
curl http://localhost:3000/api/products
```

## Lab: containerize and run

### 1. Build the image

```sh
cd sample-apps/sample-node-application
docker build -t sample-node:1.0 .
```

### 2. Run the container

```sh
docker run --name sample-node -d -p 3000:3000 sample-node:1.0
```

Optional: override the listen port inside the container:

```sh
docker run --name sample-node -d -p 3000:4000 -e PORT=4000 sample-node:1.0
```

### 3. Verify

```sh
curl http://localhost:3000/health
curl http://localhost:3000/api/products
curl -X POST http://localhost:3000/api/products \
  -H 'Content-Type: application/json' \
  -d '{"name":"USB-C Hub","price":29.99,"inStock":true}'
```

### 4. Inspect

```sh
docker ps
docker logs sample-node
docker exec -it sample-node sh -c 'whoami; node -v'
docker images sample-node
```

Teaching tip: a single-stage image that runs `npm install` with a full toolchain is usually larger than this multi-stage result. Rebuild after small code edits and watch which layers are cached.

### 5. Cleanup

```sh
docker stop sample-node
docker rm sample-node
# optional: docker rmi sample-node:1.0
```

## Dockerfile highlights

- **Deps stage:** `npm install --omit=dev` on `node:20-alpine`
- **Runtime stage:** copies only `node_modules` + app source
- **Non-root:** runs as user `app`
- **HEALTHCHECK:** uses `wget` (available on Alpine) against `/health`
