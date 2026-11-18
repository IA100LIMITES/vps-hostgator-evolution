#!/usr/bin/env bash
# =============================================================================
#  Instalador da Evolution API para a VPS HostGator (imagem "Aplicação → n8n")
#
#  O que ele faz, sem mexer no docker-compose.yml original da HostGator:
#    1. cria 2 GB de swap (se a VPS não tiver);
#    2. cria o banco "evolution" no Postgres que já existe;
#    3. sobe a Evolution API v2 na mesma rede Docker do n8n (Redis índice 1);
#    4. corrige a URL de webhook do n8n (o domínio da imagem não existe no DNS);
#    5. instala o nó n8n-nodes-evolution-api no n8n (main e worker);
#    6. mostra os endereços e a chave.
#
#  Pode rodar de novo quantas vezes quiser: ele reaproveita a chave e o banco.
#  Uso:  curl -fsSL <endereço>/instalar.sh | bash
# =============================================================================
set -Eeuo pipefail

# Tudo dentro de { ... }: o bash só executa depois de baixar o arquivo inteiro,
# então uma conexão que cai no meio do "curl | bash" não roda meio script.
{

EVOLUTION_IMAGE="evoapicloud/evolution-api:v2.3.7"
EVOLUTION_NODE_PKG="n8n-nodes-evolution-api@1.0.4"
EVOLUTION_IP_FIXO="172.24.0.50"   # longe dos .10-.14 que a HostGator fixa
N8N_DIR="/opt/n8n-traefik"
EVO_DIR="/opt/evolution"
LOG="/var/log/instalar-evolution.log"

exec > >(tee -a "$LOG") 2>&1

verde() { printf '\033[1;32m%s\033[0m\n' "$*"; }
amarelo() { printf '\033[1;33m%s\033[0m\n' "$*"; }
passo() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
erro() { printf '\n\033[1;31mERRO: %s\033[0m\n' "$*"; exit 1; }
trap 'erro "algo falhou na linha $LINENO. Veja o log em $LOG"' ERR

# -----------------------------------------------------------------------------
passo "Conferindo a VPS"
[ "$(id -u)" -eq 0 ] || erro "rode como root."
[ -f "$N8N_DIR/docker-compose.yml" ] || erro "não achei $N8N_DIR. Na compra, o sistema tem que ser 'Aplicação → n8n'."
command -v docker >/dev/null || erro "Docker não encontrado."
for c in n8n-main n8n-main-worker postgres redis traefik; do
  docker inspect "$c" >/dev/null 2>&1 || erro "o container '$c' não existe. A VPS veio diferente do esperado."
done

# espera Postgres e Redis ficarem saudáveis (útil logo depois de ligar a VPS)
for i in $(seq 1 60); do
  pg=$(docker inspect -f '{{.State.Health.Status}}' postgres 2>/dev/null || true)
  rd=$(docker inspect -f '{{.State.Health.Status}}' redis 2>/dev/null || true)
  [ "$pg" = healthy ] && [ "$rd" = healthy ] && break
  sleep 3
done
[ "$pg" = healthy ] || erro "o Postgres não ficou pronto."

env_de() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n "s/^$2=//p" | head -1 | tr -d '[:space:]'; }

DB_USER=$(env_de n8n-main DB_POSTGRESDB_USER)
DB_PASS=$(env_de n8n-main DB_POSTGRESDB_PASSWORD)
N8N_HOST_IMG=$(env_de n8n-main N8N_HOST)
REDE=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' n8n-main)

# IP público: o mesmo que a HostGator colocou na regra do Traefik
IP=$(docker inspect -f '{{index .Config.Labels "traefik.http.routers.n8n-ip.rule"}}' n8n-main | sed -n 's/.*Host(`\([0-9.]*\)`).*/\1/p')
[ -n "$IP" ] || IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
[ -n "$IP" ] || erro "não consegui descobrir o IP da VPS."

DOMINIO_BASE="${N8N_HOST_IMG#n8n.}"
EVO_HOST="evolution.${DOMINIO_BASE}"

dns_aponta() {  # o nome existe no DNS público e aponta para esta VPS?
  curl -fsS --max-time 8 "https://dns.google/resolve?name=$1&type=A" 2>/dev/null | grep -q "\"data\":\"$IP\""
}

if [ -n "$N8N_HOST_IMG" ] && dns_aponta "$N8N_HOST_IMG"; then
  N8N_URL="https://${N8N_HOST_IMG}/"
else
  N8N_URL="http://${IP}/"
fi
if dns_aponta "$EVO_HOST"; then
  EVO_URL="https://${EVO_HOST}"; EVO_HTTPS=1
else
  EVO_URL="http://${IP}:8080"; EVO_HTTPS=0
fi
echo "IP: $IP | rede: $REDE | n8n: $N8N_URL | evolution: $EVO_URL"

# -----------------------------------------------------------------------------
passo "Memória: criando swap de 2 GB (se precisar)"
if [ "$(swapon --noheadings | wc -l)" -eq 0 ]; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -q vm.swappiness=10
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  verde "swap criado"
else
  echo "a VPS já tem swap, nada a fazer"
fi

# -----------------------------------------------------------------------------
passo "Banco de dados da Evolution"
if docker exec postgres psql -U "$DB_USER" -d postgres -Atc "select 1 from pg_database where datname='evolution'" | grep -q 1; then
  echo "banco 'evolution' já existe"
else
  docker exec postgres createdb -U "$DB_USER" evolution
  verde "banco 'evolution' criado"
fi

# -----------------------------------------------------------------------------
passo "Evolution API"
mkdir -p "$EVO_DIR"
if [ -f "$EVO_DIR/.env" ] && grep -q '^AUTHENTICATION_API_KEY=' "$EVO_DIR/.env"; then
  API_KEY=$(sed -n 's/^AUTHENTICATION_API_KEY=//p' "$EVO_DIR/.env")
  echo "reaproveitando a chave que já existia"
else
  API_KEY=$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

cat > "$EVO_DIR/.env" <<EOF
SERVER_TYPE=http
SERVER_PORT=8080
SERVER_URL=${EVO_URL}
CORS_ORIGIN=*
CORS_METHODS=GET,POST,PUT,DELETE
CORS_CREDENTIALS=true
DEL_INSTANCE=false
LOG_LEVEL=ERROR,WARN,INFO
LOG_BAILEYS=error

AUTHENTICATION_API_KEY=${API_KEY}
AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true

DATABASE_ENABLED=true
DATABASE_PROVIDER=postgresql
DATABASE_CONNECTION_URI=postgresql://${DB_USER}:${DB_PASS}@postgres:5432/evolution?schema=public
DATABASE_CONNECTION_CLIENT_NAME=evolution
DATABASE_SAVE_DATA_INSTANCE=true
DATABASE_SAVE_DATA_NEW_MESSAGE=true
DATABASE_SAVE_MESSAGE_UPDATE=true
DATABASE_SAVE_DATA_CONTACTS=true
DATABASE_SAVE_DATA_CHATS=true
DATABASE_SAVE_DATA_LABELS=true
DATABASE_SAVE_DATA_HISTORIC=true

CACHE_REDIS_ENABLED=true
CACHE_REDIS_URI=redis://redis:6379/1
CACHE_REDIS_PREFIX_KEY=evolution
CACHE_REDIS_SAVE_INSTANCES=false
CACHE_LOCAL_ENABLED=false

QRCODE_LIMIT=30
CONFIG_SESSION_PHONE_CLIENT=Evolution API
CONFIG_SESSION_PHONE_NAME=Chrome
TZ=America/Sao_Paulo
EOF
chmod 600 "$EVO_DIR/.env"

LABELS=""
if [ "$EVO_HTTPS" = 1 ]; then
  LABELS=$(cat <<EOF
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.evolution.rule=Host(\`${EVO_HOST}\`)"
      - "traefik.http.routers.evolution.entrypoints=websecure"
      - "traefik.http.routers.evolution.tls.certresolver=le"
      - "traefik.http.services.evolution.loadbalancer.server.port=8080"
EOF
)
fi

cat > "$EVO_DIR/docker-compose.yml" <<EOF
services:
  evolution:
    image: ${EVOLUTION_IMAGE}
    container_name: evolution_api
    restart: always
    env_file: .env
    ports:
      - "8080:8080"
    volumes:
      - evolution_instances:/evolution/instances
    networks:
      app_network:
        ipv4_address: ${EVOLUTION_IP_FIXO}
${LABELS}

volumes:
  evolution_instances:

networks:
  app_network:
    external: true
    name: ${REDE}
EOF

cd "$EVO_DIR"
docker compose pull -q
docker compose up -d

echo -n "esperando a Evolution responder"
ok=0
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 http://127.0.0.1:8080/ >/dev/null 2>&1; then ok=1; break; fi
  echo -n "."; sleep 3
done
echo
[ "$ok" = 1 ] || erro "a Evolution não respondeu. Veja: docker logs evolution_api"
verde "Evolution no ar"

# -----------------------------------------------------------------------------
passo "n8n: URL de webhook e nó da Evolution"
OVERRIDE="$N8N_DIR/docker-compose.override.yml"
if [ "$N8N_URL" = "http://${IP}/" ]; then
  cat > "$OVERRIDE" <<EOF
# Criado pelo instalar.sh: o domínio da imagem não existe no DNS,
# então o n8n passa a mostrar as URLs com o IP. Apague este arquivo para desfazer.
services:
  n8n-main:
    environment:
      - WEBHOOK_URL=http://${IP}/
      - N8N_EDITOR_BASE_URL=http://${IP}/
EOF
else
  rm -f "$OVERRIDE"
fi

instalar_no() {  # $1 = container
  # --legacy-peer-deps: não baixa o n8n-workflow de novo (o n8n já tem)
  # --ignore-scripts: o pacote tem um preinstall "only-allow pnpm" que não serve aqui
  docker exec -u node "$1" sh -c "mkdir -p ~/.n8n/nodes && cd ~/.n8n/nodes && \
    ( [ -f package.json ] || echo '{\"name\":\"installed-nodes\",\"private\":true,\"dependencies\":{}}' > package.json ) && \
    npm install --omit=dev --legacy-peer-deps --ignore-scripts --no-audit --no-fund --loglevel=error ${EVOLUTION_NODE_PKG}"
}
instalar_no n8n-main
instalar_no n8n-main-worker
verde "nó instalado no main e no worker"

cd "$N8N_DIR"
docker compose up -d --no-deps --force-recreate n8n-main
docker restart n8n-main-worker >/dev/null

echo -n "esperando o n8n voltar"
ok=0
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${IP}/healthz" || true)
  [ "$code" = 200 ] && { ok=1; break; }
  echo -n "."; sleep 3
done
echo
[ "$ok" = 1 ] || amarelo "o n8n ainda está subindo; espere 1 minuto antes de abrir."

# -----------------------------------------------------------------------------
trap - ERR
cat <<EOF

$(verde "================================================================")
$(verde "  PRONTO! Deixe esta tela aberta, você vai usar estes dados.")
$(verde "================================================================")

  n8n (abra no navegador):
      ${N8N_URL}

  Painel da Evolution (abra no navegador):
      ${EVO_URL}/manager

  Endereço da Evolution (para a credencial no n8n):
      ${EVO_URL}

  Chave da Evolution (API Key):
      ${API_KEY}

$(verde "================================================================")
  Para ver estes dados de novo:  cat ${EVO_DIR}/LEIA-ME.txt
EOF

cat > "$EVO_DIR/LEIA-ME.txt" <<EOF
n8n:                 ${N8N_URL}
Painel Evolution:    ${EVO_URL}/manager
Endereço Evolution:  ${EVO_URL}
Chave (API Key):     ${API_KEY}
EOF
chmod 600 "$EVO_DIR/LEIA-ME.txt"

exit 0
}
