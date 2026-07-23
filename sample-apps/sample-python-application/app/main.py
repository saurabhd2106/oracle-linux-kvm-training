from __future__ import annotations

from typing import Dict, List

from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field

app = FastAPI(title="sample-python-application", version="1.0.0")


class Product(BaseModel):
    id: int
    name: str
    price: float
    inStock: bool


class ProductCreate(BaseModel):
    name: str = Field(min_length=1)
    price: float = 0.0
    inStock: bool = True


_next_id = 4
_products: Dict[int, Product] = {
    1: Product(id=1, name="Oracle Linux Cap", price=19.99, inStock=True),
    2: Product(id=2, name="Docker Sticker Pack", price=4.5, inStock=True),
    3: Product(id=3, name="KVM Lab Notebook", price=12.0, inStock=False),
}


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/products", response_model=List[Product])
def list_products() -> List[Product]:
    return list(_products.values())


@app.get("/api/products/{product_id}", response_model=Product)
def get_product(product_id: int) -> Product:
    product = _products.get(product_id)
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")
    return product


@app.post("/api/products", response_model=Product, status_code=201)
def create_product(payload: ProductCreate) -> Product:
    global _next_id
    product = Product(
        id=_next_id,
        name=payload.name.strip(),
        price=payload.price,
        inStock=payload.inStock,
    )
    _products[product.id] = product
    _next_id += 1
    return product


@app.delete("/api/products/{product_id}", status_code=204)
def delete_product(product_id: int) -> Response:
    if product_id not in _products:
        raise HTTPException(status_code=404, detail="Product not found")
    del _products[product_id]
    return Response(status_code=204)
