# Sample Python application (FastAPI)

In-memory product catalog API used to teach building and running a single Python
container. Bonus: FastAPI serves interactive docs at `/docs`.

## Learning goals

- Multi-stage Python builds (venv in builder → slim runtime)
- `EXPOSE` vs published ports
- Healthchecks, logs, and `docker exec`
- Exploring the OpenAPI UI from a container

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness |
| GET | `/api/products` | List products |
| GET | `/api/products/{id}` | Get one product |
| POST | `/api/products` | Create product (`{"name","price","inStock"}`) |
| DELETE | `/api/products/{id}` | Delete product |
| GET | `/docs` | Swagger UI (browser) |

## Run without Docker (optional)

Requires Python 3.12+:

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
curl http://localhost:8000/health
```

## Lab: containerize and run

### 1. Build the image

```sh
cd sample-apps/sample-python-application
docker build -t sample-python:1.0 .
```

### 2. Run the container

```sh
docker run --name sample-python -d -p 8000:8000 sample-python:1.0
```

### 3. Verify

```sh
curl http://localhost:8000/health
curl http://localhost:8000/api/products
curl -X POST http://localhost:8000/api/products \
  -H 'Content-Type: application/json' \
  -d '{"name":"USB-C Hub","price":29.99,"inStock":true}'
```

Open in a browser: [http://localhost:8000/docs](http://localhost:8000/docs)

### 4. Inspect

```sh
docker ps
docker logs sample-python
docker exec -it sample-python sh -c 'whoami; python --version'
docker inspect sample-python --format '{{json .State.Health}}'
```

### 5. Cleanup

```sh
docker stop sample-python
docker rm sample-python
# optional: docker rmi sample-python:1.0
```

## Dockerfile highlights

- **Builder:** creates a virtualenv and installs dependencies
- **Runtime:** copies only the venv + application code (no pip build cache)
- **Non-root:** runs as user `app`
- **HEALTHCHECK:** probes `GET /health`
