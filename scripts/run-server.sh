#!/usr/bin/env bash
set -e

# Configuración de carpetas
SERVER_DIR="$HOME/terraria-server"
WORLDS_DIR="$HOME/terraria-worlds"
WORLD_FILE="$WORLDS_DIR/$WORLD_NAME.wld"
mkdir -p "$SERVER_DIR" "$WORLDS_DIR"

echo "==> 1. Descargando Servidor de Terraria (1.4.5.8)..."
wget -q https://terraria.org/api/download/pc-dedicated-server/terraria-server-1458.zip -O terraria.zip
unzip -q terraria.zip -d "$SERVER_DIR"
cd "$SERVER_DIR/1458/Linux"
chmod +x TerrariaServer.bin.x86_64

echo "==> 2. Descargando el mundo desde el Bucket S3 ($REMOTE_BUCKET)..."
# Intentar descargar el archivo .wld desde el bucket
rclone copy "$REMOTE_BUCKET/$WORLD_NAME.wld" "$WORLDS_DIR/" --verbose || true

echo "==> 3. Generando serverconfig.txt..."

# Base de la configuración
cat <<EOF > serverconfig.txt
world=$WORLD_FILE
worldpath=$WORLDS_DIR
worldname=$WORLD_NAME
maxplayers=8
port=7777
password=
motd=ZENOBIA HELL INFIERNO MUERTE
EOF

# Validar si el mundo ya existe
if [ -f "$WORLD_FILE" ]; then
  echo "==> [OK] Mundo detectado en '$WORLD_FILE'. Se omitirá 'autocreate'."
else
  echo "==> [INFO] No se encontró un mundo existente. Configurando autocreate..."
  cat <<EOF >> serverconfig.txt
autocreate=3
difficulty=2
seed=$SEED
EOF
fi

echo "==> 4. Iniciando túnel Playit.gg en Docker..."
docker run -d --rm \
  --name playit-agent \
  --net=host \
  -e SECRET_KEY="$PLAYIT_SECRET" \
  "$PLAYIT_IMAGE"

echo "==> 5. Iniciando Servidor de Terraria..."
# Iniciar Terraria dentro de tmux en segundo plano
tmux new-session -d -s terraria "./TerrariaServer.bin.x86_64 -config serverconfig.txt"

echo "==> Servidor iniciado. Monitoreando tiempo de ejecución..."

# Función de guardado y cierre limpio
cleanup() {
  echo "==> Guardando el mundo y subiendo al Bucket S3..."
  tmux send-keys -t terraria "save" C-m
  sleep 10
  tmux send-keys -t terraria "exit" C-m
  sleep 5

  echo "==> Subiendo archivo .wld a S3 con rclone..."
  rclone copy "$WORLDS_DIR/$WORLD_NAME.wld" "$REMOTE_BUCKET/" --verbose
  echo "==> Guardado completado con éxito."
  docker stop playit-agent || true
}

# Capturar señales de cierre de GitHub Actions para siempre guardar antes de morir
trap cleanup EXIT

# Loop de monitoreo para apagar cuando falte poco para el timeout de 335 minutos
while true; do
  CURRENT_EPOCH=$(date +%s)
  if [ "$CURRENT_EPOCH" -ge "$RUN_DEADLINE_EPOCH" ]; then
    echo "==> Tiempo límite alcanzado ($RUNTIME_MINUTES min). Iniciando cierre seguro..."
    break
  fi
  
  # Si el servidor colapsa antes de tiempo, romper el loop
  if ! tmux has-session -t terraria 2>/dev/null; then
    echo "==> El proceso de Terraria se cerró inesperadamente."
    break
  fi

  sleep 30
done
