# Sample Java application (Spring Boot)

In-memory product catalog API used to teach building and running a single Java
container with a production-style multi-stage Dockerfile.

## Learning goals

- Images vs containers
- Multi-stage builds (JDK builder → JRE runtime)
- Layer caching (`pom.xml` before source)
- Port publishing (`-p`)
- Healthchecks, logs, and `docker exec`
- Non-root `USER` in the final image

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness |
| GET | `/api/products` | List products |
| GET | `/api/products/{id}` | Get one product |
| POST | `/api/products` | Create product (`{"name","price","inStock"}`) |
| DELETE | `/api/products/{id}` | Delete product |

## Run without Docker (optional)

Requires JDK 21 and Maven:

```sh
mvn -DskipTests spring-boot:run
curl http://localhost:8080/health
curl http://localhost:8080/api/products
```

## Lab: containerize and run

### 1. Build the image

```sh
cd sample-apps/sample-java-application
docker build -t sample-java:1.0 .
```

Discuss: builder stage has Maven + JDK; runtime stage is JRE-only and smaller.

### 2. Run the container

```sh
docker run --name sample-java -d -p 8080:8080 sample-java:1.0
```

### 3. Verify

```sh
curl http://localhost:8080/health
curl http://localhost:8080/api/products
curl -X POST http://localhost:8080/api/products \
  -H 'Content-Type: application/json' \
  -d '{"name":"USB-C Hub","price":29.99,"inStock":true}'
```

### 4. Inspect

```sh
docker ps
docker logs sample-java
docker exec -it sample-java sh -c 'whoami; java -version'
docker inspect sample-java --format '{{.Config.User}} {{.State.Health.Status}}'
```

### 5. Cleanup

```sh
docker stop sample-java
docker rm sample-java
# optional: docker rmi sample-java:1.0
```

## Dockerfile highlights

- **Multi-stage:** compile with `eclipse-temurin:21-jdk-jammy`, run with `21-jre-jammy`
- **Non-root:** process runs as user `app`
- **HEALTHCHECK:** probes `GET /health`
- **`.dockerignore`:** keeps `target/` and IDE files out of the build context
