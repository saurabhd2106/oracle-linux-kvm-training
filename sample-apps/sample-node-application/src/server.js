const express = require("express");

const app = express();
const PORT = Number(process.env.PORT || 3000);

app.use(express.json());

let nextId = 4;
const products = new Map([
  [1, { id: 1, name: "Oracle Linux Cap", price: 19.99, inStock: true }],
  [2, { id: 2, name: "Docker Sticker Pack", price: 4.5, inStock: true }],
  [3, { id: 3, name: "KVM Lab Notebook", price: 12.0, inStock: false }],
]);

app.get("/health", (_req, res) => {
  res.json({ status: "ok" });
});

app.get("/api/products", (_req, res) => {
  res.json(Array.from(products.values()));
});

app.get("/api/products/:id", (req, res) => {
  const product = products.get(Number(req.params.id));
  if (!product) {
    return res.status(404).json({ error: "Product not found" });
  }
  res.json(product);
});

app.post("/api/products", (req, res) => {
  const { name, price, inStock } = req.body || {};
  if (!name || typeof name !== "string" || !name.trim()) {
    return res.status(400).json({ error: "name is required" });
  }
  const product = {
    id: nextId++,
    name: name.trim(),
    price: Number(price) || 0,
    inStock: Boolean(inStock),
  };
  products.set(product.id, product);
  res.status(201).json(product);
});

app.delete("/api/products/:id", (req, res) => {
  const id = Number(req.params.id);
  if (!products.has(id)) {
    return res.status(404).json({ error: "Product not found" });
  }
  products.delete(id);
  res.status(204).send();
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`sample-node-application listening on ${PORT}`);
});
