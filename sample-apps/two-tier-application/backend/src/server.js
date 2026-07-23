const express = require("express");
const { Pool } = require("pg");

const app = express();
const PORT = Number(process.env.PORT || 3000);

app.use(express.json());

function buildPool() {
  if (process.env.DATABASE_URL) {
    return new Pool({ connectionString: process.env.DATABASE_URL });
  }

  return new Pool({
    host: process.env.DATABASE_HOST || "localhost",
    port: Number(process.env.DATABASE_PORT || 5432),
    user: process.env.DATABASE_USER || "catalog",
    password: process.env.DATABASE_PASSWORD || "catalog",
    database: process.env.DATABASE_NAME || "catalog",
  });
}

const pool = buildPool();

async function initDb() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS products (
      id SERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      price NUMERIC(10, 2) NOT NULL DEFAULT 0,
      in_stock BOOLEAN NOT NULL DEFAULT TRUE
    )
  `);

  const { rows } = await pool.query("SELECT COUNT(*)::int AS count FROM products");
  if (rows[0].count === 0) {
    await pool.query(
      `INSERT INTO products (name, price, in_stock) VALUES
        ('Oracle Linux Cap', 19.99, TRUE),
        ('Docker Sticker Pack', 4.50, TRUE),
        ('KVM Lab Notebook', 12.00, FALSE)`
    );
    console.log("Seeded products table");
  }
}

function mapProduct(row) {
  return {
    id: row.id,
    name: row.name,
    price: Number(row.price),
    inStock: row.in_stock,
  };
}

app.get("/health", async (_req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "ok", database: "up" });
  } catch (err) {
    res.status(503).json({ status: "error", database: "down", detail: err.message });
  }
});

app.get("/api/products", async (_req, res) => {
  try {
    const { rows } = await pool.query(
      "SELECT id, name, price, in_stock FROM products ORDER BY id"
    );
    res.json(rows.map(mapProduct));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/api/products/:id", async (req, res) => {
  try {
    const { rows } = await pool.query(
      "SELECT id, name, price, in_stock FROM products WHERE id = $1",
      [Number(req.params.id)]
    );
    if (rows.length === 0) {
      return res.status(404).json({ error: "Product not found" });
    }
    res.json(mapProduct(rows[0]));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/api/products", async (req, res) => {
  const { name, price, inStock } = req.body || {};
  if (!name || typeof name !== "string" || !name.trim()) {
    return res.status(400).json({ error: "name is required" });
  }
  try {
    const { rows } = await pool.query(
      `INSERT INTO products (name, price, in_stock)
       VALUES ($1, $2, $3)
       RETURNING id, name, price, in_stock`,
      [name.trim(), Number(price) || 0, Boolean(inStock)]
    );
    res.status(201).json(mapProduct(rows[0]));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.delete("/api/products/:id", async (req, res) => {
  try {
    const result = await pool.query("DELETE FROM products WHERE id = $1", [
      Number(req.params.id),
    ]);
    if (result.rowCount === 0) {
      return res.status(404).json({ error: "Product not found" });
    }
    res.status(204).send();
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

async function start() {
  const maxAttempts = 30;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      await initDb();
      break;
    } catch (err) {
      if (attempt === maxAttempts) {
        console.error("Failed to initialize database:", err.message);
        process.exit(1);
      }
      console.log(`Waiting for database (${attempt}/${maxAttempts})...`);
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }

  app.listen(PORT, "0.0.0.0", () => {
    console.log(`two-tier backend listening on ${PORT}`);
  });
}

start();
