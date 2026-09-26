#!/bin/sh
# SPDX-License-Identifier: LicenseRef-Gines-Proprietary
# Instala (ou atualiza) o gines-forge SEM root, no estilo do instalador do Claude Code:
#
#   ~/.local/share/gines-forge/versions/<versão>/   a instalação autocontida (CPython, deps, claude, codex)
#   ~/.local/share/gines-forge/current -> versions/<versão>
#   ~/.local/bin/gines-forged, ~/.local/bin/forge-cli
#   ~/.config/systemd/user/gines-forged.service     serviço de USUÁRIO
#
# Uso:  curl -fsSL https://raw.githubusercontent.com/gines-ai/gines-forge-releases/main/install.sh | sh
#       GINES_FORGE_VERSION=0.45.0 sh install.sh      # uma versão específica
# Depois disto o próprio daemon se atualiza por este canal (latest.json + sha256) e reinicia quando ocioso.
set -eu

CANAL="${GINES_FORGE_CHANNEL:-https://github.com/gines-ai/gines-forge-releases}"
RAW="${GINES_FORGE_RAW:-https://raw.githubusercontent.com/gines-ai/gines-forge-releases/main}"
BASE="${XDG_DATA_HOME:-$HOME/.local/share}/gines-forge"
BIN="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

for f in curl tar sha256sum; do command -v "$f" >/dev/null 2>&1 || { echo "preciso de $f" >&2; exit 1; }; done
[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "so Linux x86_64 por enquanto ($(uname -s)-$(uname -m))" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ -n "${GINES_FORGE_VERSION:-}" ]; then
  VERSAO="$GINES_FORGE_VERSION"
  ARQ="gines-forge-$VERSAO-x86_64-linux.tar.gz"
  URL="$CANAL/releases/download/v$VERSAO/$ARQ"
  curl -fsSL --retry 3 -o "$TMP/sha256" "$URL.sha256"
  SHA=$(cut -d' ' -f1 "$TMP/sha256")
else
  curl -fsSL --retry 3 -o "$TMP/latest.json" "$RAW/latest.json"
  # sem jq: os campos sao simples
  campo() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$TMP/latest.json" | head -1; }
  VERSAO=$(campo version); ARQ=$(campo file); SHA=$(campo sha256); URL=$(campo url)
fi
[ -n "$VERSAO" ] && [ -n "$ARQ" ] && [ -n "$SHA" ] && [ -n "$URL" ] || { echo "latest.json incompleto" >&2; exit 1; }
DEST="$BASE/versions/$VERSAO"

if [ -x "$DEST/bin/gines-forged" ]; then
  echo ">> $VERSAO ja esta instalada em $DEST"
else
  echo ">> baixando $ARQ"
  curl -fsSL --retry 3 -o "$TMP/$ARQ" "$URL"
  echo "$SHA  $TMP/$ARQ" | sha256sum -c - >/dev/null || { echo "sha256 NAO confere: pacote recusado" >&2; exit 1; }
  echo ">> extraindo em $DEST"
  mkdir -p "$BASE/versions"
  rm -rf "$DEST.partial"; mkdir -p "$DEST.partial"
  tar -xzf "$TMP/$ARQ" -C "$DEST.partial" --strip-components=1
  grep -qx "$VERSAO" "$DEST.partial/VERSION" || { echo "o pacote diz outra versao" >&2; exit 1; }
  # sanidade ANTES de virar current: o daemon do pacote responde
  "$DEST.partial/bin/gines-forged" --version >/dev/null || { echo "o daemon do pacote nao roda aqui" >&2; exit 1; }
  rm -rf "$DEST"; mv "$DEST.partial" "$DEST"
fi

echo ">> current -> versions/$VERSAO"
[ -L "$BASE/current" ] && cp -P "$BASE/current" "$BASE/previous" 2>/dev/null || true
ln -sfn "versions/$VERSAO" "$BASE/current.tmp" && mv -T "$BASE/current.tmp" "$BASE/current"
mkdir -p "$BIN"
# Scripts, nao symlinks: o wrapper do pacote resolve o proprio diretorio por $0, e um
# symlink em ~/.local/bin o faria procurar o Python la (achado do teste ponta a ponta).
for w in gines-forged forge-cli; do
  printf '#!/bin/sh\nexec "%s/current/bin/%s" "$@"\n' "$BASE" "$w" > "$BIN/$w.tmp" && chmod 755 "$BIN/$w.tmp" && mv -f "$BIN/$w.tmp" "$BIN/$w"
done

echo ">> servico de usuario"
mkdir -p "$UNIT_DIR"
if [ -f "$DEST/share/gines-forged.service" ]; then
  # A unit vem no pacote (a do repositorio, com ExecStart/PATH da instalacao por usuario).
  install -m644 "$DEST/share/gines-forged.service" "$UNIT_DIR/gines-forged.service"
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  if systemctl --user is-active --quiet gines-forged; then
    systemctl --user restart gines-forged
  else
    systemctl --user enable --now gines-forged || true
  fi
  loginctl enable-linger "$USER" 2>/dev/null || true
  sleep 1; systemctl --user --no-pager status gines-forged | head -5 || true
fi
if [ -x /usr/bin/gines-forged ] && dpkg-query -W gines-forge >/dev/null 2>&1; then
  cat <<'FIM'

  Havia um gines-forge instalado pelo .deb. A instalacao por usuario passa a valer
  (~/.local/bin vem antes no PATH e a unit de usuario sobrepoe a de /usr/lib). Quando
  quiser, remova o pacote antigo:  sudo apt remove gines-forge
FIM
fi
echo ">> pronto: gines-forge $VERSAO em $BASE/current"
