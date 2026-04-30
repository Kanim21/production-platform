-- Migration 001: Initial schema
-- Run via: psql $DATABASE_URL -f 001_init.sql
-- Idempotent: all statements use IF NOT EXISTS / CREATE OR REPLACE.

BEGIN;

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Users
CREATE TABLE IF NOT EXISTS users (
    id          BIGSERIAL PRIMARY KEY,
    email       TEXT        NOT NULL UNIQUE,
    name        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);

-- Products
CREATE TABLE IF NOT EXISTS products (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT        NOT NULL,
    description TEXT        NOT NULL DEFAULT '',
    price_cents BIGINT      NOT NULL CHECK (price_cents >= 0),
    stock       INTEGER     NOT NULL DEFAULT 0 CHECK (stock >= 0),
    sku         TEXT        UNIQUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_products_sku ON products (sku) WHERE sku IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_products_stock ON products (stock) WHERE stock > 0;

-- Orders
CREATE TABLE IF NOT EXISTS orders (
    id          BIGSERIAL   PRIMARY KEY,
    user_id     BIGINT      NOT NULL REFERENCES users(id),
    product_id  BIGINT      NOT NULL REFERENCES products(id),
    quantity    INTEGER     NOT NULL CHECK (quantity > 0),
    status      TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'paid', 'shipped', 'cancelled', 'refunded')),
    total_cents BIGINT      GENERATED ALWAYS AS (quantity * (
                    SELECT price_cents FROM products WHERE id = product_id
                )) STORED,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_orders_user_id    ON orders (user_id);
CREATE INDEX IF NOT EXISTS idx_orders_product_id ON orders (product_id);
CREATE INDEX IF NOT EXISTS idx_orders_status     ON orders (status) WHERE status IN ('pending', 'paid');
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders (created_at DESC);

-- updated_at trigger
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_users_updated_at') THEN
        CREATE TRIGGER set_users_updated_at
            BEFORE UPDATE ON users
            FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_products_updated_at') THEN
        CREATE TRIGGER set_products_updated_at
            BEFORE UPDATE ON products
            FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_orders_updated_at') THEN
        CREATE TRIGGER set_orders_updated_at
            BEFORE UPDATE ON orders
            FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
    END IF;
END;
$$;

-- Seed data for dev/staging
INSERT INTO users (email, name) VALUES
    ('alice@example.com', 'Alice Chen'),
    ('bob@example.com',   'Bob Singh')
ON CONFLICT (email) DO NOTHING;

INSERT INTO products (name, description, price_cents, stock, sku) VALUES
    ('Widget Pro',       'High-performance widget for demanding workloads',  4999,  100, 'WIDGET-PRO-001'),
    ('Gadget Basic',     'Entry-level gadget, perfect for everyday use',     1999,  250, 'GADGET-BAS-001'),
    ('Doohickey Elite',  'Premium doohickey with extended warranty',         9999,   50, 'DOOH-ELT-001'),
    ('Thingamajig',      'The original thingamajig — now with 20% more',     2999,  175, 'THING-001'),
    ('Gizmo Ultra',      'Ultra-fast gizmo, 3× faster than previous gen',   14999,   20, 'GIZMO-ULT-001')
ON CONFLICT (sku) DO NOTHING;

COMMIT;
