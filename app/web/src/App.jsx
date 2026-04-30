import { useState, useEffect, useCallback } from "react";

const API_BASE = import.meta.env.VITE_API_URL || "/api/v1";

function formatPrice(cents) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  }).format(cents / 100);
}

function ProductCard({ product, onAddToCart }) {
  return (
    <div className="product-card">
      <h3>{product.name}</h3>
      <p className="description">{product.description}</p>
      <div className="product-footer">
        <span className="price">{formatPrice(product.price_cents)}</span>
        <span className="stock">{product.stock} in stock</span>
        <button
          onClick={() => onAddToCart(product)}
          disabled={product.stock === 0}
          className="btn-primary"
        >
          Add to Cart
        </button>
      </div>
    </div>
  );
}

function CartSidebar({ cart, onCheckout, onRemove }) {
  const total = cart.reduce((sum, item) => sum + item.price_cents * item.qty, 0);

  return (
    <aside className="cart-sidebar">
      <h2>Cart ({cart.length})</h2>
      {cart.length === 0 ? (
        <p className="empty-cart">Your cart is empty</p>
      ) : (
        <>
          <ul className="cart-items">
            {cart.map((item) => (
              <li key={item.id} className="cart-item">
                <span>{item.name}</span>
                <span>×{item.qty}</span>
                <span>{formatPrice(item.price_cents * item.qty)}</span>
                <button onClick={() => onRemove(item.id)} aria-label="Remove">×</button>
              </li>
            ))}
          </ul>
          <div className="cart-total">
            <strong>Total: {formatPrice(total)}</strong>
          </div>
          <button onClick={onCheckout} className="btn-checkout">
            Checkout
          </button>
        </>
      )}
    </aside>
  );
}

export default function App() {
  const [products, setProducts] = useState([]);
  const [cart, setCart] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [checkoutStatus, setCheckoutStatus] = useState(null);

  useEffect(() => {
    let cancelled = false;

    async function fetchProducts() {
      try {
        const res = await fetch(`${API_BASE}/products`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        if (!cancelled) setProducts(data.products ?? []);
      } catch (err) {
        if (!cancelled) setError(err.message);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    fetchProducts();
    return () => { cancelled = true; };
  }, []);

  const handleAddToCart = useCallback((product) => {
    setCart((prev) => {
      const existing = prev.find((i) => i.id === product.id);
      if (existing) {
        return prev.map((i) =>
          i.id === product.id ? { ...i, qty: i.qty + 1 } : i
        );
      }
      return [...prev, { ...product, qty: 1 }];
    });
  }, []);

  const handleRemoveFromCart = useCallback((productId) => {
    setCart((prev) => prev.filter((i) => i.id !== productId));
  }, []);

  const handleCheckout = useCallback(async () => {
    setCheckoutStatus("processing");

    try {
      const results = await Promise.all(
        cart.map((item) =>
          fetch(`${API_BASE}/orders`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              product_id: item.id,
              quantity: item.qty,
              user_id: 1, // In production: from auth session
            }),
          }).then((r) => {
            if (!r.ok) throw new Error(`Order failed for ${item.name}`);
            return r.json();
          })
        )
      );

      setCart([]);
      setCheckoutStatus(`success:${results.map((r) => r.order_id).join(",")}`);
    } catch (err) {
      setCheckoutStatus(`error:${err.message}`);
    }
  }, [cart]);

  return (
    <div className="app">
      <header className="app-header">
        <h1>production-platform store</h1>
        <span className="env-badge">{import.meta.env.VITE_ENV || "dev"}</span>
      </header>

      <div className="app-body">
        <main className="product-grid-container">
          {checkoutStatus?.startsWith("success") && (
            <div className="alert alert-success">
              Orders placed! IDs: {checkoutStatus.replace("success:", "")}
            </div>
          )}
          {checkoutStatus?.startsWith("error") && (
            <div className="alert alert-error">
              Checkout failed: {checkoutStatus.replace("error:", "")}
            </div>
          )}

          {loading && <div className="loading-spinner">Loading products…</div>}
          {error && <div className="alert alert-error">Failed to load products: {error}</div>}

          {!loading && !error && products.length === 0 && (
            <p>No products in stock.</p>
          )}

          <div className="product-grid">
            {products.map((p) => (
              <ProductCard key={p.id} product={p} onAddToCart={handleAddToCart} />
            ))}
          </div>
        </main>

        <CartSidebar
          cart={cart}
          onCheckout={handleCheckout}
          onRemove={handleRemoveFromCart}
        />
      </div>
    </div>
  );
}
