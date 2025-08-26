#!/usr/bin/env bash
set -euo pipefail

# ======= CONFIG BÁSICA =======
APP_DIR=/srv/mcp-stack
DEPLOY_USER=deploy
VPS_DB_PASSWORD='Deuseeu2025@'
ADMINER_START=18081
API_START=18082
PG_START=18083
ADMINER_END=18100
API_END=18100
PG_END=18100
# ============================

find_free_port() {
  local start=$1 end=$2 port
  for ((port=start; port<=end; port++)); do
    if ! ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port"; then
      echo "$port"; return 0
    fi
  done
  return 1
}

# --- Docker install ---
if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# --- Criar usuário deploy ---
id -u "$DEPLOY_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEPLOY_USER"
usermod -aG docker "$DEPLOY_USER"

mkdir -p "$APP_DIR/api"
cd "$APP_DIR"

# --- portas livres ---
PORT_ADMINER=$(find_free_port "$ADMINER_START" "$ADMINER_END")
PORT_API=$(find_free_port "$API_START" "$API_END")
PORT_PG=$(find_free_port "$PG_START" "$PG_END")

if [[ -z "${PORT_ADMINER:-}" || -z "${PORT_API:-}" || -z "${PORT_PG:-}" ]]; then
  echo "❌ Não encontrei portas livres no range configurado."
  exit 1
fi

echo "ℹ️  Portas:"
echo "Adminer: 127.0.0.1:${PORT_ADMINER}"
echo "API:     127.0.0.1:${PORT_API}"
echo "Postgres:127.0.0.1:${PORT_PG}"

# --- docker-compose.yml ---
cat > docker-compose.yml <<YAML
services:
  postgres:
    image: postgres:16.4
    container_name: mcp-postgres
    environment:
      POSTGRES_DB: mcpdb
      POSTGRES_USER: mcpuser
      POSTGRES_PASSWORD: \${PGPASSWORD}
    ports:
      - "127.0.0.1:${PORT_PG}:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: unless-stopped

  adminer:
    image: adminer:4
    container_name: mcp-adminer
    environment:
      ADMINER_DEFAULT_SERVER: postgres
    ports:
      - "127.0.0.1:${PORT_ADMINER}:8080"
    depends_on:
      - postgres
    restart: unless-stopped

  api:
    build:
      context: ./api
      dockerfile: Dockerfile
    container_name: mcp-api
    env_file: .env
    depends_on:
      - postgres
    ports:
      - "127.0.0.1:${PORT_API}:3000"
    restart: unless-stopped

volumes:
  pgdata:
YAML

# --- .env ---
cat > .env <<ENV
PORT=3000
PGHOST=postgres
PGPORT=5432
PGUSER=mcpuser
PGPASSWORD=${VPS_DB_PASSWORD}
PGDATABASE=mcpdb
ENV

# --- package.json ---
cat > api/package.json <<'JSON'
{
  "name": "mcp-api",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "pg": "^8.12.0"
  }
}
JSON

# --- server.js ---
cat > api/server.js <<'JS'
import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import pkg from 'pg';
const { Pool } = pkg;

const app = express();
app.use(cors());
app.use(express.json());

const pool = new Pool({
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  user: process.env.PGUSER || 'mcpuser',
  password: process.env.PGPASSWORD,
  database: process.env.PGDATABASE || 'mcpdb',
  max: 10
});

app.get('/health', (_req, res) => res.json({ ok: true }));

app.get('/leads', async (_req, res) => {
  const { rows } = await pool.query('SELECT * FROM leads ORDER BY id DESC LIMIT 100');
  res.json(rows);
});

app.post('/leads', async (req, res) => {
  const { name, email } = req.body || {};
  if (!name || !email) return res.status(400).json({ error: 'name/email required' });
  const { rows } = await pool.query(
    'INSERT INTO leads (name, email) VALUES ($1,$2) RETURNING *',
    [name, email]
  );
  res.status(201).json(rows[0]);
});

async function migrate() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS leads (
      id SERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      email TEXT UNIQUE NOT NULL,
      created_at TIMESTAMP NOT NULL DEFAULT NOW()
    )
  `);
}
const PORT = Number(process.env.PORT || 3000);
migrate().then(() => {
  app.listen(PORT, () => console.log(\`API http://0.0.0.0:\${PORT}\`));
}).catch(err => {
  console.error('migrate/start error', err);
  process.exit(1);
});
JS

# --- Dockerfile ---
cat > api/Dockerfile <<'DOCKER'
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm npm ci || npm i --omit=dev
COPY server.js ./
EXPOSE 3000
CMD ["npm","run","start"]
DOCKER

# --- limpeza containers antigos ---
echo "🧹 Limpando containers antigos..."
docker rm -f mcp-postgres >/dev/null 2>&1 || true
docker rm -f mcp-adminer  >/dev/null 2>&1 || true
docker rm -f mcp-api      >/dev/null 2>&1 || true

# --- subir stack ---
echo "🐳 Subindo containers..."
docker compose up -d --build
echo
docker compose ps
echo
echo "✅ VPS pronta!"
echo "- Adminer:  http://127.0.0.1:${PORT_ADMINER}"
echo "- API:      http://127.0.0.1:${PORT_API}/health"
echo "- Postgres: host 127.0.0.1, porta ${PORT_PG}, user mcpuser, senha ${VPS_DB_PASSWORD}, db mcpdb"
