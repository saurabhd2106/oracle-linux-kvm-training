import { useEffect, useState } from "react";

async function fetchProducts() {
  const res = await fetch("/api/products");
  if (!res.ok) {
    throw new Error(`Failed to load products (${res.status})`);
  }
  return res.json();
}

export default function App() {
  const [products, setProducts] = useState([]);
  const [name, setName] = useState("");
  const [price, setPrice] = useState("9.99");
  const [inStock, setInStock] = useState(true);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);

  async function load() {
    setLoading(true);
    setError("");
    try {
      setProducts(await fetchProducts());
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  async function onCreate(event) {
    event.preventDefault();
    setError("");
    try {
      const res = await fetch("/api/products", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name,
          price: Number(price),
          inStock,
        }),
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || `Create failed (${res.status})`);
      }
      setName("");
      setPrice("9.99");
      setInStock(true);
      await load();
    } catch (err) {
      setError(err.message);
    }
  }

  async function onDelete(id) {
    setError("");
    try {
      const res = await fetch(`/api/products/${id}`, { method: "DELETE" });
      if (!res.ok && res.status !== 204) {
        throw new Error(`Delete failed (${res.status})`);
      }
      await load();
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <main className="page">
      <header>
        <p className="eyebrow">Three-tier Docker lab</p>
        <h1>Product Catalog</h1>
        <p className="lede">
          Browser → nginx frontend → Node backend → PostgreSQL
        </p>
      </header>

      <section className="panel">
        <h2>Add product</h2>
        <form onSubmit={onCreate} className="form">
          <label>
            Name
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="USB-C Hub"
              required
            />
          </label>
          <label>
            Price
            <input
              type="number"
              min="0"
              step="0.01"
              value={price}
              onChange={(e) => setPrice(e.target.value)}
              required
            />
          </label>
          <label className="checkbox">
            <input
              type="checkbox"
              checked={inStock}
              onChange={(e) => setInStock(e.target.checked)}
            />
            In stock
          </label>
          <button type="submit">Create</button>
        </form>
      </section>

      <section className="panel">
        <div className="row">
          <h2>Products</h2>
          <button type="button" className="secondary" onClick={load}>
            Refresh
          </button>
        </div>
        {loading && <p>Loading…</p>}
        {error && <p className="error">{error}</p>}
        {!loading && products.length === 0 && <p>No products yet.</p>}
        <ul className="list">
          {products.map((product) => (
            <li key={product.id}>
              <div>
                <strong>{product.name}</strong>
                <span>
                  ${product.price.toFixed(2)} ·{" "}
                  {product.inStock ? "in stock" : "out of stock"}
                </span>
              </div>
              <button
                type="button"
                className="danger"
                onClick={() => onDelete(product.id)}
              >
                Delete
              </button>
            </li>
          ))}
        </ul>
      </section>
    </main>
  );
}
