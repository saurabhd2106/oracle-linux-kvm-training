# Three-tier application (React + Node + PostgreSQL)

Browser UI, API, and database — the classic production topology for teaching how
containers talk to each other.

## Architecture

```text
Browser
   |
   v
frontend (nginx:80)  --proxy /api-->  backend (node:3000)  -->  db (postgres:5432)
```

The React app calls relative URLs (`/api/...`). nginx in the frontend container
proxies those requests to the backend service name `backend` on the Compose
network. The browser never needs to know the backend hostname.

## Learning goals

- Frontend → backend via reverse proxy (same-origin)
- Backend → database via Docker DNS + env config
- Multi-stage frontend build (Node builder → nginx runtime)
- Multi-service Compose with health-gated startup
- Optional contrast: CORS when publishing the API separately

## Lab: bring up the stack

```sh
cd sample-apps/3-tier-application
docker compose up -d --build
docker compose ps
```

Open the UI: [http://localhost:8080](http://localhost:8080)

### Verify the proxy path

From the host, both of these hit the **frontend** published port; nginx forwards
API calls to the backend:

```sh
curl http://localhost:8080/health
curl http://localhost:8080/api/products
```

Direct backend (published for teaching/debugging):

```sh
curl http://localhost:3000/health
curl http://localhost:3000/api/products
```

### Create a product in the UI, then confirm in Postgres

```sh
docker compose exec db psql -U catalog -d catalog -c 'SELECT * FROM products;'
```

### Inspect networking

```sh
docker compose exec frontend sh -c 'wget -qO- http://backend:3000/health'
docker compose exec backend sh -c 'getent hosts db'
docker compose logs frontend backend db
```

### Cleanup

```sh
docker compose down        # keep volume
docker compose down -v     # delete DB data too
```

## Run locally without Docker (optional)

Terminal 1 — database:

```sh
docker compose up -d db
```

Terminal 2 — backend:

```sh
cd backend && npm install
DATABASE_HOST=localhost npm start
```

Terminal 3 — frontend (Vite proxies `/api` to localhost:3000):

```sh
cd frontend && npm install
npm run dev
```

Open [http://localhost:5173](http://localhost:5173).

## Teaching notes

- **Why nginx proxy?** Production frontends often terminate HTTP and reverse-proxy
  `/api` to an internal service. Delegates see container-to-container traffic
  without fighting browser CORS.
- **CORS alternative:** if the UI called `http://localhost:3000` directly, the
  backend would need CORS headers. Mention it; the proxy path is the default here.
- **Secrets:** DB password is in Compose env for the lab only — do not bake it into
  Dockerfiles or commit real credentials.

## Layout

```text
3-tier-application/
  frontend/          # Vite + React → nginx image
  backend/           # Express + pg
  docker-compose.yml
  README.md
```
